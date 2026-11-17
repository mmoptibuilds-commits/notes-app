import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/hlc.dart';
import '../core/ids.dart';
import 'migrations.dart';

/// The database on disk was written by a newer version of the app.
class DatabaseTooNewException implements Exception {
  DatabaseTooNewException(this.found, this.supported);
  final int found;
  final int supported;
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
  AppDatabase._(this._db, this.path, this.deviceId, this.clock, this._seq);

  final Database _db;

  /// File path, or null for an in-memory database.
  final String? path;

  /// This device's id. Stable for the life of the database.
  final String deviceId;

  final HlcClock clock;
  int _seq;
  int _depth = 0;
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
  }) {
    if (key != null && key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'must be 32 bytes');
    }
    final db = path == null ? sqlite3.openInMemory() : sqlite3.open(path);
    try {
      if (key != null) db.execute("PRAGMA key = 'raw:${hex(key)}'");
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
      db.execute('PRAGMA busy_timeout = 5000');

      if (found > schema.length) {
        throw DatabaseTooNewException(found, schema.length);
      }
      if (found > 0 && found < schema.length && path != null) {
        final backup = '$path.pre-v${schema.length}.bak';
        final f = File(backup);
        if (f.existsSync()) f.deleteSync();
        db.execute('VACUUM INTO ?', [backup]);
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
      return AppDatabase._(db, path, deviceId, clock, seq)
        .._persistedHlc = clock.last;
    } catch (_) {
      db.close();
      rethrow;
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
      final result = body();
      if (_seq != seqBefore) setMeta('seq', '$_seq');
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
    Directory(p.dirname(target)).createSync(recursive: true);
    _db.execute('VACUUM INTO ?', [target]);
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

extension on Hlc {
  bool operator >=(Hlc other) => compareTo(other) >= 0;
}

class _Notifier extends ChangeNotifier {
  void fire() => notifyListeners();
}
