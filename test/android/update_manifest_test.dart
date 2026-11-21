import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();

  // INTERNET was already in the merged release manifest through a plugin; it
  // is declared here explicitly because sync and update checks need it.
  test('declares only INTERNET and the package installer permission', () {
    final perms = RegExp(r'<uses-permission android:name="([^"]+)"')
        .allMatches(manifest)
        .map((m) => m.group(1))
        .toList();
    expect(perms, [
      'android.permission.INTERNET',
      'android.permission.REQUEST_INSTALL_PACKAGES',
    ]);
  });

  test('the install result receiver is not exported', () {
    expect(
      manifest,
      contains(
        '<receiver android:name=".update.InstallResultReceiver" '
        'android:exported="false"/>',
      ),
    );
  });

  test('no FileProvider: updates go through a PackageInstaller session', () {
    expect(manifest.contains('FileProvider'), isFalse);
    expect(
      File('android/app/src/main/res/xml/file_paths.xml').existsSync(),
      isFalse,
    );
  });

  test('backups stay disabled', () {
    expect(manifest, contains('android:allowBackup="false"'));
  });

  test('the activity registers the updater plugin', () {
    final kt = File(
      'android/app/src/main/kotlin/com/mmoptibuilds/notes/MainActivity.kt',
    ).readAsStringSync();
    expect(kt, contains('UpdaterPlugin.register(flutterEngine, this)'));
  });
}
