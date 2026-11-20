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
import '../update/platform_installer.dart';
import '../update/update_controller.dart';

/// The long-lived objects of a running app.
class AppServices {
  AppServices(
    this.db,
    this.notes,
    this.settings,
    this.dataDir, {
    this.sync,
    this.updates,
  });

  final AppDatabase db;
  final NoteRepository notes;
  final AppSettings settings;

  /// Device sync. Null in tests that do not exercise it.
  final SyncService? sync;

  /// Update checking and installation. Null in tests and on platforms without
  /// self-update.
  final UpdateController? updates;

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

  /// Called by the Linux updater once its helper is running: closes the
  /// database and sync cleanly and exits, so the helper (which waits for this
  /// process) can replace the program files. User data is not touched.
  Future<void> quitForUpdate() async {
    // Let any debounced autosave or retry write finish first.
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    sync?.dispose();
    db.close();
    exit(0);
  }

  void close() {
    updates?.dispose();
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
  late final AppServices services;
  final installer = createPlatformInstaller(
    onQuit: () => services.quitForUpdate(),
  );
  final updates = installer == null
      ? null
      : UpdateController.forApp(settings: settings, installer: installer);
  services = AppServices(
    db,
    notes,
    settings,
    dir,
    sync: sync,
    updates: updates,
  );
  return services;
}
