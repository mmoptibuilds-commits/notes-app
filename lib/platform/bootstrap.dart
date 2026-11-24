import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/ids.dart';
import '../data/app_database.dart';
import '../data/app_settings.dart';
import '../data/editor_save_barrier.dart';
import '../data/note_repository.dart';
import '../sync/peers.dart';
import '../sync/sync_service.dart';
import '../sync/cloud/cloud_api.dart';
import '../sync/cloud/cloud_config.dart';
import '../sync/cloud/cloud_service.dart';
import 'cloud_login.dart';
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
    this.cloud,
    this.updates,
    EditorSaveBarrier? saveBarrier,
    this.exitProcess = exit,
  }) : saveBarrier = saveBarrier ?? EditorSaveBarrier();

  final AppDatabase db;
  final NoteRepository notes;
  final AppSettings settings;

  /// Device sync. Null in tests that do not exercise it.
  final SyncService? sync;

  /// Optional private cloud sync, null when no server URL is configured.
  final CloudService? cloud;

  /// Update checking and installation. Null in tests and on platforms without
  /// self-update.
  final UpdateController? updates;

  /// Coordinates live editor saves and failed-save handoffs before Linux
  /// starts its update helper.
  final EditorSaveBarrier saveBarrier;

  final void Function(int) exitProcess;

  /// Directory holding the database and local backups.
  final String dataDir;

  /// For tests: everything in memory, nothing on disk or in a keystore.
  factory AppServices.inMemory({
    int Function()? clock,
    void Function(int) exitProcess = exit,
  }) {
    final db = AppDatabase.open(null, wallClock: clock);
    return AppServices(
      db,
      NoteRepository(db, nowMs: clock),
      AppSettings(db),
      '',
      exitProcess: exitProcess,
    );
  }

  /// Called before helper setup. It freezes editors and confirms every
  /// pending editor save, including snapshots handed off by disposed editors.
  Future<void> prepareForUpdate() => saveBarrier.prepare();

  /// Releases a prepared barrier when helper setup fails and Notes stays open.
  Future<void> abortUpdatePreparation() async => saveBarrier.release();

  /// Called only after the helper is running: closes sync and the database,
  /// then exits so the helper can replace the program files. User data is not
  /// touched.
  Future<void> quitForUpdate() async {
    try {
      sync?.dispose();
      cloud?.dispose();
    } on Object {
      // The helper is waiting for this process to exit; keep shutting down.
    }
    try {
      db.close();
    } on Object {
      // The helper is waiting for this process to exit; keep shutting down.
    } finally {
      exitProcess(0);
    }
  }

  void close() {
    updates?.dispose();
    sync?.dispose();
    cloud?.dispose();
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

/// Startup stopped because the Linux update helper is still replacing program
/// files. The app can be opened again after the swap finishes.
class UpdateSwapInProgressException implements Exception {
  const UpdateSwapInProgressException();

  @override
  String toString() =>
      'Notes is finishing an update. Wait a few seconds, then open Notes again.';
}

/// Waits for another process holding the updater's per-user lock. The caller
/// must run this before opening the database or other app state.
Future<void> waitForUpdateSwapLock(
  File lockFile, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final directory = lockFile.parent;
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError('The Notes update state directory is a symlink.');
  }
  await directory.create(recursive: true);
  if (FileSystemEntity.typeSync(lockFile.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError('The Notes update lock is a symlink.');
  }
  if (!lockFile.existsSync()) lockFile.createSync();
  final seconds = timeout.inSeconds.clamp(1, 60);
  final result = await Process.run('flock', [
    '-w',
    '$seconds',
    lockFile.path,
    '/bin/true',
  ]);
  if (result.exitCode == 1) throw const UpdateSwapInProgressException();
  if (result.exitCode != 0) {
    throw StateError('Notes could not check its Linux update lock safely.');
  }
}

Future<void> _waitForLinuxUpdateSwap(String? dataOverride) async {
  if (!Platform.isLinux || dataOverride != null) return;
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return;
  final stateHome = Platform.environment['XDG_STATE_HOME'];
  final stateBase = stateHome != null && stateHome.isNotEmpty
      ? stateHome
      : p.join(home, '.local/state');
  final dataHome = Platform.environment['XDG_DATA_HOME'];
  final dataBase = dataHome != null && dataHome.isNotEmpty
      ? dataHome
      : p.join(home, '.local/share');
  var stateRoot = p.normalize(p.join(stateBase, 'com.mmoptibuilds.notes'));
  final dataRoot = p.normalize(p.join(dataBase, 'com.mmoptibuilds.notes'));
  if (stateRoot == dataRoot ||
      p.isWithin(dataRoot, stateRoot) ||
      p.isWithin(stateRoot, dataRoot)) {
    stateRoot = p.normalize(
      p.join(home, '.local/state/com.mmoptibuilds.notes'),
    );
  }
  await waitForUpdateSwapLock(File(p.join(stateRoot, 'updater/lock')));
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
  await _waitForLinuxUpdateSwap(override);
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
    onPrepareQuit: () => services.prepareForUpdate(),
    onConfirmStillClean: () => services.saveBarrier.confirmStillClean(),
    onQuit: () => services.quitForUpdate(),
    onInstallAborted: () => services.abortUpdatePreparation(),
  );
  final updates = installer == null
      ? null
      : UpdateController.forApp(settings: settings, installer: installer);
  final cloudUrl = resolveCloudUrl(
    environment: Platform.environment,
    compiledUrl: const String.fromEnvironment('NOTES_CLOUD_URL'),
  );
  // A development instance keeps its cloud session in its own directory.
  final CloudSessionStore cloudSessionStore =
      (Platform.environment['NOTES_DATA_DIR'] ?? '').isNotEmpty
      ? FileCloudSessionStore(dir)
      : const SecureCloudSessionStore();
  final cloud = cloudUrl.isEmpty
      ? null
      : CloudService(
          repo: notes,
          api: HttpCloudApi(
            baseUrl: Uri.parse(cloudUrl),
            sessions: cloudSessionStore,
          ),
          sessions: cloudSessionStore,
          dataDir: dir,
          deviceName: settings.deviceName,
          loginLauncher: _cloudLoginLauncher(),
          unavailable: false,
        );
  sync.suppressAutoSync = () => cloud?.active ?? false;
  await cloud?.restoreState();
  services = AppServices(
    db,
    notes,
    settings,
    dir,
    sync: sync,
    cloud: cloud,
    updates: updates,
  );
  return services;
}

CloudLoginLauncher? _cloudLoginLauncher() {
  try {
    return createCloudLoginLauncher();
  } on UnsupportedError {
    return null;
  }
}
