import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

import '../core/app_version.dart';
import 'installer.dart';
import 'pinned_keys.dart';
import 'version_compare.dart';

/// The channel the Kotlin `UpdaterPlugin` listens on.
const kUpdaterChannelName = 'com.mmoptibuilds.notes/updater';

/// Android installer. Authenticity of the APK rests on the pinned signing
/// certificate and the OS (a package with a different signer cannot replace
/// this app), plus the signed manifest when a key is pinned. The APK goes in
/// through a PackageInstaller session; the user always confirms in the
/// system dialog. No silent install, no root.
class AndroidUpdateInstaller implements UpdateInstaller {
  AndroidUpdateInstaller({
    MethodChannel? channel,
    this.certSha256 = kReleaseCertSha256,
    this.installTimeout = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _channel = channel ?? const MethodChannel(kUpdaterChannelName),
       _now = now ?? DateTime.now;

  final MethodChannel _channel;

  /// SHA-256 (lower-case hex) of the only signing certificate accepted.
  final String certSha256;
  final Duration installTimeout;
  final DateTime Function() _now;

  @override
  bool get acceptsUnsignedManifest => true;

  Future<Map<Object?, Object?>> _map(String method, [Object? args]) async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>(method, args);
    if (r == null) throw PlatformException(code: 'empty', message: method);
    return r;
  }

  File _pendingFile(Directory dir) => File('${dir.path}/pending.json');

  @override
  Future<InstallerInfo> prepare() async {
    const platform = UpdatePlatform(UpdateOs.android, 'arm64');
    try {
      final v = await _map('installedVersion');
      final dir = await _channel.invokeMethod<String>('updateCacheDir');
      if (dir == null || dir.isEmpty) {
        throw PlatformException(code: 'no_dir');
      }
      final code = v['versionCode'];
      final sdk = v['sdkInt'];
      final abis = (v['abis'] as List?)?.whereType<String>().toList() ?? [];
      final installedBuild = code is int ? code : 0;
      UpdateBlock? block;
      if (v['packageName'] != kUpdateAppId || installedBuild <= 0) {
        block = const UpdateBlock(
          BlockKind.unsupportedOs,
          'Notes could not read its own version from Android.',
        );
      } else if (sdk is int && sdk < 28) {
        block = const UpdateBlock(
          BlockKind.unsupportedOs,
          'In-app updates need Android 9 or newer. Install the new APK '
          'yourself instead.',
        );
      } else if (abis.isNotEmpty && !abis.contains('arm64-v8a')) {
        block = const UpdateBlock(
          BlockKind.unsupportedArch,
          'Updates are only published for 64-bit ARM phones.',
        );
      }
      return InstallerInfo(
        platform: platform,
        installedVersion: (v['versionName'] as String?) ?? appVersionName,
        installedBuild: installedBuild,
        updateDir: Directory(dir),
        block: block,
      );
    } on MissingPluginException {
      return InstallerInfo(
        platform: platform,
        installedVersion: appVersionName,
        installedBuild: appBuildNumber,
        updateDir: Directory(Directory.systemTemp.path),
        block: const UpdateBlock(
          BlockKind.unsupportedOs,
          'In-app updates are not available in this build.',
        ),
      );
    }
  }

  @override
  Future<int?> freeSpace(String path) async {
    try {
      return await _channel.invokeMethod<int>('freeSpace', {'path': path});
    } on Object {
      return null;
    }
  }

  @override
  Future<void> verifyDownloaded(ReadyUpdate update, InstallerInfo info) async {
    final Map<Object?, Object?> r;
    try {
      r = await _map('inspectApk', {'path': update.file.path});
    } on PlatformException {
      throw const UpdateVerificationFailure(
        'Android could not read the downloaded package.',
      );
    }
    if (r['supported'] == false) {
      throw const UpdateVerificationFailure(
        'This Android version cannot check the downloaded package.',
      );
    }
    final artifact = update.candidate.artifact;
    if (r['packageName'] != kUpdateAppId) {
      throw const UpdateVerificationFailure(
        'The downloaded package is for a different app.',
      );
    }
    final code = r['versionCode'];
    if (code is! int || code != artifact.versionCode) {
      throw const UpdateVerificationFailure(
        'The downloaded package is not the version the release declares.',
      );
    }
    if (!isNewerAndroidVersionCode(
      installedVersionCode: info.installedBuild,
      candidateVersionCode: code,
    )) {
      throw const UpdateVerificationFailure(
        'The downloaded package is not newer than the installed one.',
      );
    }
    final signers = (r['signerSha256'] as List?)
        ?.whereType<String>()
        .map((s) => s.toLowerCase())
        .toList();
    if (signers == null || signers.length != 1) {
      throw const UpdateVerificationFailure(
        'The downloaded package does not have exactly one signing '
        'certificate.',
      );
    }
    if (signers.single != certSha256.toLowerCase()) {
      throw const UpdateVerificationFailure(
        'The downloaded package is signed by a different certificate than '
        'Notes. It was discarded.',
      );
    }
    final declared = artifact.certSha256;
    if (declared != null && declared.toLowerCase() != signers.single) {
      throw const UpdateVerificationFailure(
        'The release metadata names a different signing certificate.',
      );
    }
  }

  @override
  Future<InstallStart> install(ReadyUpdate update, InstallerInfo info) async {
    final bool can;
    try {
      can = await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on PlatformException catch (e) {
      return InstallFailed(e.message ?? 'Android refused the request.');
    }
    if (!can) return const InstallNeedsPermission();

    final candidate = update.candidate;
    final pending = _pendingFile(info.updateDir);
    try {
      await pending.parent.create(recursive: true);
      final temporary = File('${pending.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'toVersion': candidate.version,
          'toVersionCode': candidate.artifact.versionCode,
          'time': _now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      if (await pending.exists()) await pending.delete();
      await temporary.rename(pending.path);
    } on FileSystemException {
      // Without the marker the next launch just shows nothing; keep going.
    }
    try {
      final r = await _map('install', {
        'path': update.file.path,
      }).timeout(installTimeout);
      switch (r['status']) {
        case 'handedToOs':
          return const InstallHandedToOs(willRestart: false);
        case 'cancelled':
          await _clear(pending);
          return const InstallCancelled();
        case 'needsPermission':
          await _clear(pending);
          return const InstallNeedsPermission();
        default:
          await _clear(pending);
          return InstallFailed(
            (r['message'] as String?) ??
                'Android could not install the update.',
          );
      }
    } on TimeoutException {
      await _clear(pending);
      return const InstallFailed('Android did not respond in time.');
    } on PlatformException catch (e) {
      await _clear(pending);
      return InstallFailed(
        e.message ?? 'Android could not install the update.',
      );
    }
  }

  @override
  Future<InstallOutcome?> lastOutcome(InstallerInfo info) async {
    final file = _pendingFile(info.updateDir);
    try {
      if (!await file.exists()) return null;
      final j = jsonDecode(await file.readAsString());
      await _clear(file);
      if (j is! Map<String, dynamic>) return null;
      final version = j['toVersion'];
      final code = j['toVersionCode'];
      final time = j['time'];
      if (version is! String || code is! int || time is! String) return null;
      if (info.installedBuild == code) {
        return InstallOutcome(
          id: 'android:$time',
          updated: true,
          version: version,
          message: 'Updated to $version.',
        );
      }
      if (info.installedBuild > code) return null;
      return InstallOutcome(
        id: 'android:$time',
        updated: false,
        version: version,
        message: 'The update to $version was not installed.',
      );
    } on Object {
      await _clear(file);
      return null;
    }
  }

  @override
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } on Object {
      // Nothing useful to do; the screen explains the manual path.
    }
  }

  Future<void> _clear(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on Object {
      // Best effort.
    }
  }
}
