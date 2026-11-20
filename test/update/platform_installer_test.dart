import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/update/linux_installer.dart';
import 'package:notes/update/platform_installer.dart';

void main() {
  test('Linux gets the Linux installer wired to the quit callback', () {
    final i = createPlatformInstaller(onQuit: () async {});
    if (Platform.isLinux) {
      expect(i, isA<LinuxUpdateInstaller>());
      expect(i!.acceptsUnsignedManifest, isFalse);
    }
  });
}
