import 'dart:io';

import 'android_installer.dart';
import 'installer.dart';
import 'linux_installer.dart';

/// The installer for the platform Notes is running on, or null where updates
/// are not supported. [onQuit] is called on Linux after the update helper has
/// been started: it must flush pending saves, close the database and sync,
/// and exit the app so the helper can swap the files.
UpdateInstaller? createPlatformInstaller({
  required Future<void> Function() onQuit,
}) {
  if (Platform.isAndroid) return AndroidUpdateInstaller();
  if (Platform.isLinux) return LinuxUpdateInstaller(onQuit: onQuit);
  return null;
}
