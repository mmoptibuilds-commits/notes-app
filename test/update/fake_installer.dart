import 'dart:io';

import 'package:notes/update/installer.dart';

/// A scriptable installer for controller tests.
class FakeInstaller implements UpdateInstaller {
  FakeInstaller({
    required this.platform,
    required this.updateDir,
    this.installedVersion = '1.0.0',
    this.installedBuild = 20261122,
    this.accepts = false,
  });

  UpdatePlatform platform;
  final Directory updateDir;
  String installedVersion;
  int installedBuild;
  bool accepts;
  UpdateBlock? block;
  UpdateVerificationFailure? verifyFailure;
  InstallStart installResult = const InstallHandedToOs(willRestart: true);
  InstallOutcome? outcome;
  int? free;
  int prepares = 0;
  int installs = 0;
  int settingsOpened = 0;
  final installed = <ReadyUpdate>[];

  @override
  bool get acceptsUnsignedManifest => accepts;

  @override
  Future<InstallerInfo> prepare() async {
    prepares++;
    return InstallerInfo(
      platform: platform,
      installedVersion: installedVersion,
      installedBuild: installedBuild,
      updateDir: updateDir,
      block: block,
    );
  }

  @override
  Future<int?> freeSpace(String path) async => free;

  @override
  Future<void> verifyDownloaded(ReadyUpdate update, InstallerInfo info) async {
    final f = verifyFailure;
    if (f != null) throw f;
  }

  @override
  Future<InstallStart> install(ReadyUpdate update, InstallerInfo info) async {
    installs++;
    installed.add(update);
    return installResult;
  }

  @override
  Future<InstallOutcome?> lastOutcome(InstallerInfo info) async => outcome;

  @override
  Future<void> openInstallSettings() async => settingsOpened++;
}
