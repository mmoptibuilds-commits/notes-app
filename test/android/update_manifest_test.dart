import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();

  // INTERNET was already in the merged release manifest through a plugin; it
  // is declared here explicitly because sync and update checks need it.
  test('declares network, package installer and notification permissions', () {
    final perms = RegExp(r'<uses-permission android:name="([^"]+)"')
        .allMatches(manifest)
        .map((m) => m.group(1))
        .toList();
    expect(perms, [
      'android.permission.INTERNET',
      'android.permission.REQUEST_INSTALL_PACKAGES',
      'android.permission.POST_NOTIFICATIONS',
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

  test(
    'package replacement receiver is private and listens for the system action',
    () {
      expect(
        manifest,
        contains(
          '<receiver android:name=".update.PackageReplacedReceiver" '
          'android:exported="false">',
        ),
      );
      expect(
        manifest,
        contains(
          '<action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>',
        ),
      );
      final receiver = File(
        'android/app/src/main/kotlin/com/mmoptibuilds/notes/update/PackageReplacedReceiver.kt',
      ).readAsStringSync();
      expect(receiver, contains('PendingIntent.getActivity'));
      expect(receiver, contains('installedCode != expectedCode'));
      expect(receiver, isNot(contains('startActivity(')));
    },
  );

  test('updates use persistent app-private storage and request notifications in context', () {
    final plugin = File(
      'android/app/src/main/kotlin/com/mmoptibuilds/notes/update/UpdaterPlugin.kt',
    ).readAsStringSync();
    final storage = File(
      'android/app/src/main/kotlin/com/mmoptibuilds/notes/update/UpdateStorage.kt',
    ).readAsStringSync();
    expect(storage, contains('context.applicationContext'));
    expect(storage, contains('app.filesDir, "updates"'));
    expect(plugin, contains('REQUEST_POST_NOTIFICATIONS'));
    expect(plugin, contains('owner.requestPermissions'));
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
