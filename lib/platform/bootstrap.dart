import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/ids.dart';
import '../data/app_database.dart';
import '../data/app_settings.dart';
import '../data/note_repository.dart';
import '../sync/peers.dart';
import '../sync/sync_service.dart';

/// The long-lived objects of a running app.
class AppServices {
  AppServices(this.db, this.notes, this.settings, this.dataDir, {this.sync});

  final AppDatabase db;
  final NoteRepository notes;
  final AppSettings settings;

  /// Device sync. Null in tests that do not exercise it.
  final SyncService? sync;

  /// Directory holding the database and local backups.
  final String dataDir;

  /// For tests: everything in memory, nothing on disk or in a keystore.
  factory AppServices.inMemory({int Function()? clock}) {
    final db = AppDatabase.open(null, wallClock: clock);
    return AppServices(
      db,
      NoteRepository(db, nowMs: clock),
      AppSettings(db),
      '',
    );
  }

  void close() {
    sync?.dispose();
    settings.dispose();
    db.close();
  }
}

/// The database file is there but its key is not. Starting anyway would mean
/// creating an empty database over the user's notes, so the app stops instead.
class DatabaseKeyMissingException implements Exception {
  DatabaseKeyMissingException(this.databasePath);
  final String databasePath;
  @override
  String toString() =>
      'The notes database exists at $databasePath but its encryption key is '
      'not in the system keystore.';
}

/// Where the 32-byte database key is kept.
abstract interface class KeyStore {
  Future<Uint8List?> read();
  Future<void> write(Uint8List key);
}

/// Android Keystore / Linux Secret Service (GNOME Keyring).
class SecureKeyStore implements KeyStore {
  const SecureKeyStore();
  static const _name = 'notes.db.key.v1';
  static const _storage = FlutterSecureStorage();

  @override
  Future<Uint8List?> read() async {
    final v = await _storage.read(key: _name);
    return v == null ? null : base64Decode(v);
  }

  @override
  Future<void> write(Uint8List key) =>
      _storage.write(key: _name, value: base64Encode(key));
}

/// Key in a file beside the database. Only for development instances started
/// with `NOTES_DATA_DIR`: it keeps them out of the real keyring and offers no
/// protection.
class FileKeyStore implements KeyStore {
  FileKeyStore(this.path);
  final String path;

  @override
  Future<Uint8List?> read() async {
    final f = File(path);
    return f.existsSync() ? base64Decode(f.readAsStringSync().trim()) : null;
  }

  @override
  Future<void> write(Uint8List key) async =>
      File(path).writeAsStringSync(base64Encode(key), flush: true);
}

/// Opens the app's database, creating it and its key on first run.
///
/// Throws [DatabaseKeyMissingException] when a database exists without a key,
/// and [DatabaseUnreadableException] when the key does not fit.
Future<AppServices> bootstrap({String? dataDir, KeyStore? keyStore}) async {
  final override = dataDir ?? Platform.environment['NOTES_DATA_DIR'];
  final dir = override ?? (await getApplicationSupportDirectory()).path;
  Directory(dir).createSync(recursive: true);
  final store =
      keyStore ??
      (override == null
          ? const SecureKeyStore()
          : FileKeyStore(p.join(dir, 'dev.key')));

  final dbPath = p.join(dir, 'notes.db');
  var key = await store.read();
  if (key == null) {
    if (File(dbPath).existsSync()) throw DatabaseKeyMissingException(dbPath);
    key = randomBytes(32);
    await store.write(key);
    // Make sure the key really is retrievable before any note depends on it.
    final check = await store.read();
    if (check == null || hex(check) != hex(key)) {
      throw StateError('The system keystore did not keep the database key.');
    }
  }
  final db = AppDatabase.open(dbPath, key: key);
  final notes = NoteRepository(db);
  final settings = AppSettings(db);
  // Only a database created by this very launch can need the introduction.
  if (db.createdNow) settings.write('onboarding', 'pending');
  final identity = await DeviceIdentity.loadOrCreate(db);
  final sync = SyncService(
    repo: notes,
    peers: PeerStore(db),
    identity: identity,
    deviceName: settings.deviceName,
    // A second instance (development) must not fight over the same port.
    port: override == null ? defaultSyncPort : 0,
  );
  settings.addListener(() => sync.deviceName = settings.deviceName);
  return AppServices(db, notes, settings, dir, sync: sync);
}
