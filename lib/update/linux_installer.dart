import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_version.dart';
import 'download_service.dart';
import 'installer.dart';

/// Process access behind an interface so tests never start a real process.
abstract class UpdateProcessLauncher {
  /// Runs a short command and waits for it (used for `chmod`).
  Future<int> run(String executable, List<String> args);

  /// Starts [executable] detached from this process so it survives Notes
  /// exiting.
  Future<void> startDetached(String executable, List<String> args);
}

class SystemProcessLauncher implements UpdateProcessLauncher {
  const SystemProcessLauncher();

  @override
  Future<int> run(String executable, List<String> args) async =>
      (await Process.run(executable, args)).exitCode;

  @override
  Future<void> startDetached(String executable, List<String> args) async {
    await Process.start(executable, args, mode: ProcessStartMode.detached);
  }
}

const kManagedInstallMarker = '.managed-install';
const kUpdateHelperRelativePath = 'update/notes-update-helper';

/// Linux installer. It only ever updates a copy of Notes that the Notes
/// installer put in the user's own directory (`~/.local/opt/notes` with a
/// `.managed-install` marker). Applying is delegated to a helper script that
/// runs after Notes exits; this class verifies, hands over, and quits.
///
/// Nothing here uses sudo or touches anything outside the install directory,
/// the updater state directory and a private temp directory.
class LinuxUpdateInstaller implements UpdateInstaller {
  LinuxUpdateInstaller({
    required this.onQuit,
    UpdateProcessLauncher? launcher,
    Map<String, String>? environment,
    String? resolvedExecutable,
    String? installDir,
    int? currentPid,
    Directory? tempRoot,
    FreeSpaceProbe? freeSpaceProbe,
    UpdatePlatform? platform,
  }) : _launcher = launcher ?? const SystemProcessLauncher(),
       _env = environment ?? Platform.environment,
       _exe = resolvedExecutable ?? Platform.resolvedExecutable,
       _pid = currentPid ?? pid,
       _tempRoot = tempRoot ?? Directory.systemTemp,
       _freeSpace = freeSpaceProbe ?? dfFreeSpace,
       _platform = platform ?? UpdatePlatform.current(),
       _installOverride = installDir;

  /// Called after the helper has been started. The app flushes saves, closes
  /// the database and sync, and exits so the helper can swap the files.
  final Future<void> Function() onQuit;

  final UpdateProcessLauncher _launcher;
  final Map<String, String> _env;
  final String _exe;
  final int _pid;
  final Directory _tempRoot;
  final FreeSpaceProbe _freeSpace;
  final UpdatePlatform _platform;
  final String? _installOverride;

  @override
  bool get acceptsUnsignedManifest => false;

  String get _home => _env['HOME'] ?? '';

  /// The install directory updates apply to.
  String get installDir =>
      _installOverride ?? p.join(_home, '.local/opt/notes');

  String get _stateBase {
    final xdg = _env['XDG_STATE_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : p.join(_home, '.local/state');
    return p.join(base, 'com.mmoptibuilds.notes');
  }

  /// The helper's state directory (status file, lock). Never the data dir.
  String get stateDir => p.join(_stateBase, 'updater');

  /// Where downloaded archives go. Never the data dir.
  String get updatesDir => p.join(_stateBase, kUpdatesDirName);

  String get helperPath => p.join(installDir, kUpdateHelperRelativePath);

  @override
  Future<InstallerInfo> prepare() async {
    UpdateBlock? block;
    if (_platform.os != UpdateOs.linux || _platform.arch != 'x64') {
      block = const UpdateBlock(
        BlockKind.unsupportedArch,
        'Updates are only published for 64-bit Intel/AMD Linux.',
      );
    } else if (_home.isEmpty && _installOverride == null) {
      block = _manual('Notes could not find your home directory.');
    } else if (!_runningFromInstall()) {
      block = _manual(
        'This copy of Notes is not the one installed in $installDir.',
      );
    } else if (!File(p.join(installDir, kManagedInstallMarker)).existsSync()) {
      block = _manual('This install was not made by the Notes installer.');
    } else if (!File(helperPath).existsSync()) {
      block = _manual('This install has no update helper.');
    }
    return InstallerInfo(
      platform: _platform,
      installedVersion: appVersionName,
      installedBuild: appBuildNumber,
      updateDir: Directory(updatesDir),
      block: block,
    );
  }

  UpdateBlock _manual(String why) => UpdateBlock(
    BlockKind.unmanagedInstall,
    '$why Notes cannot update itself here. Download the new '
    '.tar.gz from the Notes releases page, unpack it and run its install.sh.',
  );

  bool _runningFromInstall() {
    try {
      final dir = Directory(installDir);
      if (!dir.existsSync()) return false;
      final root = dir.resolveSymbolicLinksSync();
      final exe = File(_exe).resolveSymbolicLinksSync();
      return p.isWithin(root, exe);
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<void> openInstallSettings() async {}

  @override
  Future<int?> freeSpace(String path) => _freeSpace(path);

  @override
  Future<void> verifyDownloaded(ReadyUpdate update, InstallerInfo info) async {
    // Size and SHA-256 were proven by the download service against the signed
    // manifest; the helper proves them again before it extracts anything.
    if (!update.file.existsSync()) {
      throw const UpdateVerificationFailure('The downloaded file is missing.');
    }
  }

  @override
  Future<InstallStart> install(ReadyUpdate update, InstallerInfo info) async {
    if (info.block != null) return InstallFailed(info.block!.message);
    final c = update.candidate;
    if (!c.signed) {
      return const InstallFailed('Release signing key not provisioned.');
    }
    final Directory helperDir;
    try {
      await Directory(stateDir).create(recursive: true);
      helperDir = await _tempRoot.createTemp('notes-update-');
      await _chmod(helperDir.path);
      final helper = File(p.join(helperDir.path, 'notes-update-helper'));
      await File(helperPath).copy(helper.path);
      // File.copy does not promise to keep the executable bit.
      await _chmod(helper.path);
      await _launcher.startDetached(helper.path, [
        'apply',
        '--pid',
        '$_pid',
        '--archive',
        update.file.path,
        '--sha256',
        c.artifact.sha256,
        '--size',
        '${c.artifact.size}',
        '--install',
        installDir,
        '--state-dir',
        stateDir,
        '--version',
        c.version,
        '--relaunch',
      ]);
    } on Object {
      return const InstallFailed('Notes could not start the updater.');
    }
    await onQuit();
    return const InstallHandedToOs(willRestart: true);
  }

  @override
  Future<InstallOutcome?> lastOutcome(InstallerInfo info) async {
    final file = File(p.join(stateDir, 'update.json'));
    try {
      if (!file.existsSync() || file.lengthSync() > 64 * 1024) return null;
      final j = jsonDecode(await file.readAsString());
      if (j is! Map<String, dynamic>) return null;
      final ok = j['ok'];
      final to = j['toVersion'];
      final time = j['time'];
      if (ok is! bool || to is! String || time is! String) return null;
      final id = 'linux:$time';
      if (ok) {
        if (to != info.installedVersion) return null;
        return InstallOutcome(
          id: id,
          updated: true,
          version: to,
          message: 'Updated to $to.',
        );
      }
      final error = _clean(j['error']);
      return InstallOutcome(
        id: id,
        updated: false,
        version: to,
        message:
            'The update to $to did not finish'
            '${error.isEmpty ? '' : ': $error'}. Your notes are stored '
            'separately and were not touched.',
      );
    } on Object {
      return null;
    }
  }

  Future<void> _chmod(String path) async {
    if (await _launcher.run('chmod', ['700', path]) != 0) {
      throw const FileSystemException('chmod failed');
    }
  }

  static String _clean(Object? v) {
    if (v is! String) return '';
    final s = v.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }
}
