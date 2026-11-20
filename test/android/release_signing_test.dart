import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'release signing has no debug-key fallback and has a clear failure path',
    () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();

      expect(gradle, isNot(contains('signingConfigs.getByName("debug")')));
      expect(gradle, contains('gradle.taskGraph.whenReady'));
      expect(gradle, contains('releaseSigningReady'));
      expect(gradle, contains('throw GradleException('));
      expect(gradle, contains('android/key.properties is missing'));
      expect(gradle, contains('storeFile does not exist'));
    },
  );
}
