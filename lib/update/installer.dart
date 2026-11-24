import 'dart:io';

import 'github_release_client.dart';
import 'manifest.dart';

enum UpdateOs { android, linux, other }

/// The platform and CPU architecture this build runs on, in the manifest's
/// vocabulary (`linux`/`x64`, `android`/`arm64`).
class UpdatePlatform {
  const UpdatePlatform(this.os, this.arch);

  final UpdateOs os;
  final String arch;

  String get name => os.name;

  static UpdatePlatform current() {
    if (Platform.isAndroid) {
      return const UpdatePlatform(UpdateOs.android, 'arm64');
    }
    if (Platform.isLinux) {
      final v = Platform.version;
      final arch = v.contains('linux_arm64')
          ? 'arm64'
          : v.contains('linux_x64')
          ? 'x64'
          : 'other';
      return UpdatePlatform(UpdateOs.linux, arch);
    }
    return const UpdatePlatform(UpdateOs.other, 'other');
  }
}

enum BlockKind {
  signingKeyNotProvisioned,
  unsupportedOs,
  unsupportedArch,
  unmanagedInstall,
  installPermission,
}

/// Why installing is not possible right now. [message] is user-facing.
class UpdateBlock {
  const UpdateBlock(this.kind, this.message);
  final BlockKind kind;
  final String message;
}

/// What the installer knows about this installation.
class InstallerInfo {
  const InstallerInfo({
    required this.platform,
    required this.installedVersion,
    required this.installedBuild,
    required this.updateDir,
    this.block,
  });

  final UpdatePlatform platform;
  final String installedVersion;

  /// Linux: the compiled-in build number. Android: the package manager's
  /// versionCode for the installed package.
  final int installedBuild;

  /// Private directory for downloaded artifacts. Never under the data dir.
  final Directory updateDir;

  /// Set when this install can never apply an update (unmanaged Linux
  /// install, Android older than 9, unsupported CPU).
  final UpdateBlock? block;
}

/// A release the user could install, fully validated against the manifest.
class UpdateCandidate {
  const UpdateCandidate({
    required this.release,
    required this.manifest,
    required this.artifact,
    required this.assetUrl,
    required this.signed,
    required this.platform,
  });

  final GithubRelease release;
  final UpdateManifest manifest;
  final ManifestArtifact artifact;
  final Uri assetUrl;

  /// False when no manifest key is pinned: nothing about the metadata is
  /// authenticated.
  final bool signed;
  final UpdatePlatform platform;

  String get version => manifest.version;
  int get size => artifact.size;
  String get notes => release.notes;
}

/// A downloaded, size- and checksum-verified artifact.
class ReadyUpdate {
  const ReadyUpdate(this.candidate, this.file);
  final UpdateCandidate candidate;
  final File file;
}

/// A downloaded file failed a platform check (wrong package, wrong signer).
class UpdateVerificationFailure implements Exception {
  const UpdateVerificationFailure(this.reason);
  final String reason;

  @override
  String toString() => 'UpdateVerificationFailure: $reason';
}

sealed class InstallStart {
  const InstallStart();
}

/// The OS now owns the installation. Never "success": Android may still ask
/// the user, and Linux swaps files after Notes has exited.
class InstallHandedToOs extends InstallStart {
  const InstallHandedToOs({required this.willRestart});
  final bool willRestart;
}

/// Android has not allowed this app to install packages yet.
class InstallNeedsPermission extends InstallStart {
  const InstallNeedsPermission();
}

class InstallCancelled extends InstallStart {
  const InstallCancelled();
}

class InstallFailed extends InstallStart {
  const InstallFailed(this.message, {this.retry = false});
  final String message;

  /// True when the failure can be retried from the ready state, without
  /// downloading or re-verifying another artifact.
  final bool retry;
}

/// What an earlier install attempt turned out to be, discovered on a later
/// launch. [id] identifies it so it is reported once.
class InstallOutcome {
  const InstallOutcome({
    required this.id,
    required this.updated,
    required this.version,
    required this.message,
  });

  final String id;

  /// True when the installed version is now the one that was pending.
  final bool updated;
  final String version;
  final String message;
}

/// Everything platform-specific about applying an update. The core logic
/// (checking, verifying, downloading) is shared; only this differs.
abstract class UpdateInstaller {
  /// Android may install when no manifest key is pinned, because the OS and
  /// the pinned signing certificate authenticate the APK. Linux may not.
  bool get acceptsUnsignedManifest;

  Future<InstallerInfo> prepare();

  /// Free bytes under [path], or null when unknown. Used for the free-space
  /// check before a download.
  Future<int?> freeSpace(String path);

  /// Platform checks on a downloaded artifact, after size and checksum.
  /// Throws [UpdateVerificationFailure].
  Future<void> verifyDownloaded(ReadyUpdate update, InstallerInfo info);

  Future<InstallStart> install(ReadyUpdate update, InstallerInfo info);

  /// The result of an earlier install attempt, if there is one to report.
  Future<InstallOutcome?> lastOutcome(InstallerInfo info);

  /// Android: opens the system page that lets this app install packages.
  Future<void> openInstallSettings() async {}
}

/// Convenience for the shared download directory name.
const kUpdatesDirName = 'updates';
