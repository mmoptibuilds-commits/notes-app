import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_stable_version.dart' as version_check;
import '../../tool/verify_release_apk.dart' as apk_check;

void main() {
  group('APK signer output validation', () {
    const expected =
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    const releaseOutput = '''
Signer #1 certificate DN: CN=Notes Release, O=Notes, C=IN
Signer #1 certificate SHA-256 digest: AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA
''';
    const debugOutput = '''
Signer #1 certificate DN: CN=Android Debug, O=Android, C=US
Signer #1 certificate SHA-256 digest: AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA
''';

    test('accepts configured release fingerprint', () {
      apk_check.verifyApkSignerOutput(releaseOutput, expected);
    });

    test('rejects Android Debug certificate', () {
      expect(
        () => apk_check.verifyApkSignerOutput(debugOutput, expected),
        throwsFormatException,
      );
    });

    test('rejects a fingerprint mismatch and malformed output', () {
      expect(
        () => apk_check.verifyApkSignerOutput(
          releaseOutput,
          'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        ),
        throwsFormatException,
      );
      expect(
        () => apk_check.parseApkSignerOutput(
          'Signer #1 certificate DN: CN=Notes',
        ),
        throwsFormatException,
      );
    });
  });

  group('stable Android versionCode validation', () {
    test('extracts the pubspec build number', () {
      expect(version_check.versionCodeFromPubspec('version: 2.1.0+12\n'), 12);
    });

    test('requires a build number and rejects malformed versions', () {
      expect(
        () => version_check.versionCodeFromPubspec('version: 2.1.0\n'),
        throwsFormatException,
      );
      expect(
        () => version_check.versionCodeFromPubspec('version: 2.1.0+abc\n'),
        throwsFormatException,
      );
    });

    test('fails when the new code is equal to or below the previous code', () {
      expect(
        () => version_check.validateStableVersionCode(10, 10),
        throwsFormatException,
      );
      expect(
        () => version_check.validateStableVersionCode(9, 10),
        throwsFormatException,
      );
    });

    test('accepts a greater code and rejects malformed previous codes', () {
      expect(
        () => version_check.validateStableVersionCode(11, 10),
        returnsNormally,
      );
      expect(
        () => version_check.parsePreviousVersionCode('not-a-number'),
        throwsFormatException,
      );
    });
  });
}
