import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/hlc.dart';
import '../core/ids.dart';
import 'migrations.dart';

/// The database on disk was written by a newer version of the app.
class DatabaseTooNewException implements Exception {
  DatabaseTooNewException(this.found, this.supported, {this.databasePath});
  final int found;
  final int supported;
  final String? databasePath;

  String? get recoveryBackupPath =>
      databasePath == null ? null : '$databasePath.pre-v$found.bak';
  @override
  String toString() =>
      'Database schema $found is newer than this app supports ($supported).';
}

/// The file exists but cannot be read with the given key (wrong or missing
/// key, or not a database).
class DatabaseUnreadableException implements Exception {
  DatabaseUnreadableException(this.path, this.cause);
  final String path;
  final Object cause;
  @override
  String toString() => 'Cannot open database at $path: $cause';
}

/// Owns the SQLite connection: encryption key, pragmas, migrations,
/// transactions, the device clock and the local change counter.
///
/// [changes] fires once after every committed transaction that wrote.
class AppDatabase {
  AppDatabase._(
    this._db,
    this.path,
    this.deviceId,
    this.clock,
    this._seq, {
    this.createdNow = false,
    Uint8List? key,
  }) : _key = key == null ? null : Uint8List.fromList(key);

  final Database _db;

  /// True when this call to [open] created the database (schema version 0).
  /// Never true for an existing database, including one just migrated.
  final bool createdNow;

  /// File path, or null for an in-memory database.
  final String? path;

  /// This device's id. Stable for the life of the database.
  final String deviceId;

  final HlcClock clock;
  final Uint8List? _key;
  int _seq;
  int _depth = 0;
  int _savepointId = 0;
  bool _dirty = false;
  Hlc _persistedHlc = Hlc.zero;

  final _changes = _Notifier();

  /// Notifies after each committed write transaction.
  Listenable get changes => _changes;

  Database get raw => _db;

  /// Opens (creating and migrating as needed) the database at [path], or an
  /// in-memory database when [path] is null.
  ///
  /// [key] must be 32 bytes when given. With a key the file is encrypted;
  /// opening an existing encrypted file without the right key throws
  /// [DatabaseUnreadableException] and leaves the file untouched.
  ///
  /// Before an existing database is migrated, a copy is written next to it as
  /// `<name>.pre-v<N>.bak` (encrypted with the same key).
  static AppDatabase open(
    String? path, {
    Uint8List? key,
    int Function()? wallClock,
    List<List<String>> schema = migrations,
    @visibleForTesting
    void Function(String backupPath)? beforeMigrationBackupReplace,
  }) {
    if (key != null && key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'must be 32 bytes');
    }
    RandomAccessFile? openLock;
    var lockHeld = false;
    try {
      if (path != null) {
        final lockPath = '$path.open.lock';
        if (FileSystemEntity.typeSync(lockPath, followLinks: false) ==
            FileSystemEntityType.link) {
          throw StateError('The database open lock is a symlink.');
        }
        openLock = File(lockPath).openSync(mode: FileMode.append);
        openLock.lockSync(FileLock.exclusive);
        lockHeld = true;
      }
      final db = path == null ? sqlite3.openInMemory() : sqlite3.open(path);
      try {
        if (key != null) db.execute("PRAGMA key = 'raw:${hex(key)}'");
        // Set this before journal-mode changes or schema migration so a second
        // process waits for a committed writer instead of failing immediately.
        db.execute('PRAGMA busy_timeout = 5000');
        final int found;
        try {
          // First statement that touches the file: fails here on a wrong key.
          found = db.userVersion;
          db.select('SELECT count(*) FROM sqlite_master');
        } on SqliteException catch (e) {
          throw DatabaseUnreadableException(path ?? ':memory:', e);
        }
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA synchronous = NORMAL');
        db.execute('PRAGMA foreign_keys = ON');

        if (found > schema.length) {
          throw DatabaseTooNewException(
            found,
            schema.length,
            databasePath: path,
          );
        }
        if (found > 0 && found < schema.length && path != null) {
          final backup = '$path.pre-v${schema.length}.bak';
          _writeVerifiedCopy(
            db,
            backup,
            key: key,
            expectedVersion: found,
            replace: true,
            beforeReplace: beforeMigrationBackupReplace == null
                ? null
                : () => beforeMigrationBackupReplace(backup),
          );
        }
        for (var v = found; v < schema.length; v++) {
          db.execute('BEGIN IMMEDIATE');
          try {
            for (final statement in schema[v]) {
              db.execute(statement);
            }
            db.userVersion = v + 1;
            db.execute('COMMIT');
          } catch (_) {
            db.execute('ROLLBACK');
            rethrow;
          }
        }

        String? meta(String k) {
          final rows = db.select('SELECT value FROM local_meta WHERE key = ?', [
            k,
          ]);
          return rows.isEmpty ? null : rows.first['value'] as String;
        }

        var deviceId = meta('device_id');
        if (deviceId == null) {
          deviceId = newDeviceId();
          db.execute(
            "INSERT INTO local_meta(key, value) VALUES ('device_id', ?)",
            [deviceId],
          );
        }
        final lastHlc = meta('hlc_last');
        final clock = HlcClock(
          deviceId,
          wallClock: wallClock,
          last: lastHlc == null ? null : Hlc.parse(lastHlc),
        );
        final seq = int.parse(meta('seq') ?? '0');
        return AppDatabase._(
          db,
          path,
          deviceId,
          clock,
          seq,
          createdNow: found == 0,
          key: key,
        ).._persistedHlc = clock.last;
      } catch (_) {
        db.close();
        rethrow;
      }
    } finally {
      if (lockHeld) openLock!.unlockSync();
      openLock?.closeSync();
    }
  }

  /// Runs [body] atomically. Nested calls join the outer transaction. If
  /// [body] throws, everything it wrote is rolled back and the error rethrown.
  T transaction<T>(T Function() body) {
    if (_depth > 0) {
      _depth++;
      try {
        return body();
      } finally {
        _depth--;
      }
    }
    final seqBefore = _seq;
    final hlcBefore = clock.last;
    _db.execute('BEGIN IMMEDIATE');
    _depth = 1;
    try {
      // More than one process may have this database open. BEGIN IMMEDIATE
      // serializes writers, but each connection's in-memory clock/counter can
      // be stale after another process commits. Refresh both while holding the
      // write lock before issuing any stamps or sequence numbers.
      final storedSeq = int.parse(getMeta('seq') ?? '0');
      if (storedSeq > _seq) _seq = storedSeq;
      final storedHlc = getMeta('hlc_last');
      if (storedHlc != null) clock.observe(Hlc.parse(storedHlc));
      final seqAtStart = _seq;
      final result = body();
      if (_seq != seqAtStart) setMeta('seq', '$_seq');
      if (clock.last != _persistedHlc) setMeta('hlc_last', clock.last.encode());
      _db.execute('COMMIT');
      _persistedHlc = clock.last;
      _depth = 0;
      if (_dirty) {
        _dirty = false;
        _changes.fire();
      }
      return result;
    } catch (_) {
      _depth = 0;
      _dirty = false;
      _seq = seqBefore;
      // The clock is deliberately not rewound: stamps must never repeat.
      assert(clock.last >= hlcBefore);
      if (!_db.autocommit) _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Runs one recoverable unit inside the current transaction. SQL writes,
  /// local sequence allocation, and change notifications roll back together.
  T savepoint<T>(T Function() body) {
    assert(_depth > 0, 'savepoint outside a transaction');
    final name = 'notes_sp_${_savepointId++}';
    final seqBefore = _seq;
    final dirtyBefore = _dirty;
    _db.execute('SAVEPOINT $name');
    try {
      final result = body();
      _db.execute('RELEASE $name');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK TO $name');
      _db.execute('RELEASE $name');
      _seq = seqBefore;
      _dirty = dirtyBefore;
      rethrow;
    }
  }

  /// Marks the current transaction as having changed user-visible data.
  void markChanged() {
    assert(_depth > 0, 'markChanged outside a transaction');
    _dirty = true;
  }

  /// Next local change sequence number. Only valid inside [transaction].
  int nextSeq() {
    assert(_depth > 0, 'nextSeq outside a transaction');
    return ++_seq;
  }

  /// Highest sequence number handed out so far.
  int get currentSeq => _seq;

  String? getMeta(String key) {
    final rows = _db.select('SELECT value FROM local_meta WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setMeta(String key, String value) => _db.execute(
    'INSERT INTO local_meta(key, value) VALUES (?, ?) '
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  /// Writes a consistent copy of the whole database to [target] (encrypted
  /// with the same key). Fails if [target] exists.
  void snapshotTo(String target) {
    _writeVerifiedCopy(
      _db,
      target,
      key: _key,
      expectedVersion: _db.userVersion,
      replace: false,
    );
    if (p.basename(target).startsWith('before-import-') &&
        p.extension(target) == '.db') {
      _pruneImportSnapshots(p.dirname(target), _key);
    }
  }

  ResultSet select(String sql, [List<Object?> args = const []]) =>
      _db.select(sql, args);

  void execute(String sql, [List<Object?> args = const []]) =>
      _db.execute(sql, args);

  void close() {
    _changes.dispose();
    _db.close();
  }
}

const _maxImportSnapshots = 7;

void _writeVerifiedCopy(
  Database source,
  String target, {
  required Uint8List? key,
  required int expectedVersion,
  required bool replace,
  void Function()? beforeReplace,
}) {
  Directory(p.dirname(target)).createSync(recursive: true);
  final lockPath = p.join(p.dirname(target), '.notes-snapshot.write.lock');
  if (FileSystemEntity.typeSync(lockPath, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError('The database snapshot lock is a symlink.');
  }
  final targetLock = File(lockPath).openSync(mode: FileMode.append);
  var lockHeld = false;
  try {
    targetLock.lockSync(FileLock.exclusive);
    lockHeld = true;
    if (!replace &&
        FileSystemEntity.typeSync(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw FileSystemException('Snapshot already exists', target);
    }
    final temporary = File('$target.tmp-${newId()}');
    try {
      source.execute('VACUUM INTO ?', [temporary.path]);
      _verifyDatabaseCopy(
        temporary.path,
        key: key,
        expectedVersion: expectedVersion,
      );
      beforeReplace?.call();
      // The temporary file is next to the destination, so rename is atomic on
      // the supported Linux and Android filesystems. The old verified copy is
      // untouched until this point.
      temporary.renameSync(target);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  } finally {
    if (lockHeld) targetLock.unlockSync();
    targetLock.closeSync();
  }
}

void _verifyDatabaseCopy(
  String path, {
  required Uint8List? key,
  int? expectedVersion,
}) {
  final copy = sqlite3.open(path);
  try {
    if (key != null) copy.execute("PRAGMA key = 'raw:${hex(key)}'");
    copy.select('SELECT count(*) FROM sqlite_master');
    final version = copy.userVersion;
    if (expectedVersion != null && version != expectedVersion) {
      throw StateError('Database snapshot has unexpected schema version.');
    }
    final check = copy.select('PRAGMA quick_check');
    if (check.length != 1 || check.first.values.first != 'ok') {
      throw StateError('Database snapshot did not pass quick_check.');
    }
  } finally {
    copy.close();
  }
}

void _pruneImportSnapshots(String directoryPath, Uint8List? key) {
  final directory = Directory(directoryPath);
  if (!directory.existsSync()) return;
  final snapshots = <File>[];
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (!name.startsWith('before-import-') || p.extension(name) != '.db') {
      continue;
    }
    try {
      _verifyDatabaseCopy(entity.path, key: key);
      snapshots.add(entity);
    } on Object {
      // An unverified older copy is left untouched; it may still be useful
      // for manual recovery even when it cannot be opened automatically.
    }
  }
  snapshots.sort(
    (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
  );
  if (snapshots.length <= _maxImportSnapshots) return;
  var usable = snapshots.length;
  for (final old in snapshots.skip(_maxImportSnapshots)) {
    if (usable <= 1) break;
    try {
      old.deleteSync();
      usable--;
    } on FileSystemException {
      // Keep the excess snapshot if cleanup fails.
    }
  }
}

extension on Hlc {
  bool operator >=(Hlc other) => compareTo(other) >= 0;
}

class _Notifier extends ChangeNotifier {
  void fire() => notifyListeners();
}
