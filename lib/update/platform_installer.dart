import 'dart:io';

import 'android_installer.dart';
import 'installer.dart';
import 'linux_installer.dart';

/// The installer for the platform Notes is running on, or null where updates
/// are not supported. On Linux, [onPrepareQuit] must freeze editors and
/// confirm their saves before helper setup; [onQuit] closes services and exits
/// after the helper starts. [onInstallAborted] releases the freeze if setup
/// fails.
UpdateInstaller? createPlatformInstaller({
  Future<void> Function() onPrepareQuit = _noOp,
  void Function() onConfirmStillClean = _noOpSync,
  required Future<void> Function() onQuit,
  Future<void> Function() onInstallAborted = _noOp,
}) {
  if (Platform.isAndroid) return AndroidUpdateInstaller();
  if (Platform.isLinux) {
    return LinuxUpdateInstaller(
      onPrepareQuit: onPrepareQuit,
      onConfirmStillClean: onConfirmStillClean,
      onQuit: onQuit,
      onInstallAborted: onInstallAborted,
    );
  }
  return null;
}

Future<void> _noOp() async {}

void _noOpSync() {}
