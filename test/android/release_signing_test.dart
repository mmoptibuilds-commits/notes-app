import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'release signing has no debug-key fallback and has a clear failure path',
    () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();

      expect(gradle, contains('} else if (cloudTest) {'));
      expect(
        gradle,
        contains('signingConfig = signingConfigs.getByName("debug")'),
      );
      expect(gradle, contains('gradle.taskGraph.whenReady'));
      expect(gradle, contains('releaseSigningReady'));
      expect(gradle, contains('throw GradleException('));
      expect(gradle, contains('android/key.properties is missing'));
      expect(gradle, contains('storeFile does not exist'));
      expect(
        gradle,
        contains('providers.gradleProperty("cloudTest").orNull == "true"'),
      );
      expect(
        gradle,
        contains(
          'if (isReleasePackagingTask && !cloudTest && !releaseSigningReady)',
        ),
      );
      expect(gradle, contains('applicationIdSuffix = ".cloudtest"'));
      expect(gradle, contains('signingConfigs.getByName("debug")'));
      expect(gradle, contains('manifestPlaceholders["cloudAuthScheme"]'));
    },
  );
}
