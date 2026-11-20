import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/app_version.dart';

void main() {
  test('app_version.dart matches pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(line, 'version: $appVersionName+$appBuildNumber');
  });

  test('the build number is above the version already on the phone', () {
    expect(appBuildNumber, greaterThan(20261121));
  });
}
