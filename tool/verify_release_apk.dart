/// Verify a release APK with Android SDK `apksigner`.
///
/// Usage: `dart tool/verify_release_apk.dart <apk> [--expected-sha256 <digest>]`
/// If no digest is supplied, `tool/release_cert_sha256.txt` must contain the
/// expected public certificate SHA-256 fingerprint. This script never opens a
/// keystore or `android/key.properties`.
library;

import 'dart:io';

class ApkSignerCertificate {
  const ApkSignerCertificate({required this.sha256, required this.isDebug});

  final String sha256;
  final bool isDebug;
}

/// Parses the certificate identity from `apksigner verify --print-certs` text.
/// The caller must also check that the `apksigner` process exited successfully.
ApkSignerCertificate parseApkSignerOutput(String output) {
  final fingerprints =
      RegExp(
            r'^Signer #\d+ certificate SHA-256 digest:\s*(.+?)\s*$',
            multiLine: true,
            caseSensitive: false,
          )
          .allMatches(output)
          .map((match) => normalizeFingerprint(match.group(1)!))
          .toList();
  if (fingerprints.length != 1) {
    throw FormatException(
      'Expected exactly one signer SHA-256 certificate digest; found ${fingerprints.length}.',
    );
  }

  final subjects = RegExp(
    r'^Signer #\d+ certificate DN:\s*(.*?)\s*$',
    multiLine: true,
    caseSensitive: false,
  ).allMatches(output).map((match) => match.group(1)!).toList();
  final isDebug = subjects.any(
    (subject) => RegExp(
      r'\bCN\s*=\s*Android Debug\b',
      caseSensitive: false,
    ).hasMatch(subject),
  );
  return ApkSignerCertificate(sha256: fingerprints.single, isDebug: isDebug);
}

String normalizeFingerprint(String value) {
  final normalized = value.replaceAll(RegExp(r'[:\s]'), '').toUpperCase();
  if (!RegExp(r'^[0-9A-F]{64}$').hasMatch(normalized)) {
    throw FormatException(
      'Invalid SHA-256 certificate fingerprint in apksigner output.',
    );
  }
  return normalized;
}

void verifyApkSignerOutput(String output, String expectedFingerprint) {
  final expected = normalizeFingerprint(expectedFingerprint);
  final signer = parseApkSignerOutput(output);
  if (signer.isDebug) {
    throw const FormatException(
      'APK is signed with an Android Debug certificate.',
    );
  }
  if (signer.sha256 != expected) {
    throw FormatException(
      'APK signer fingerprint does not match the configured expected fingerprint.',
    );
  }
}

Future<void> main(List<String> args) async {
  try {
    String? apkPath;
    String? expected;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--expected-sha256') {
        if (expected != null || i + 1 >= args.length) {
          throw const FormatException(
            '--expected-sha256 requires one fingerprint.',
          );
        }
        expected = args[++i];
      } else if (args[i].startsWith('--') || apkPath != null) {
        throw const FormatException(
          'Usage: dart tool/verify_release_apk.dart <apk> [--expected-sha256 <digest>]',
        );
      } else {
        apkPath = args[i];
      }
    }
    if (apkPath == null) {
      throw const FormatException(
        'Usage: dart tool/verify_release_apk.dart <apk> [--expected-sha256 <digest>]',
      );
    }
    if (expected == null) {
      final fingerprintFile = File('tool/release_cert_sha256.txt');
      if (!fingerprintFile.existsSync() ||
          fingerprintFile.readAsStringSync().trim().isEmpty) {
        throw const FormatException(
          'No expected certificate fingerprint is configured. Pass --expected-sha256 '
          'or add the public fingerprint to tool/release_cert_sha256.txt.',
        );
      }
      expected = fingerprintFile.readAsStringSync().trim();
    }

    final apk = File(apkPath);
    if (!apk.existsSync() ||
        FileSystemEntity.typeSync(apk.path) != FileSystemEntityType.file) {
      throw FormatException('APK does not exist: $apkPath');
    }
    final apksigner = findApksigner();
    final result = await Process.run(apksigner, [
      'verify',
      '--print-certs',
      apk.path,
    ]);
    if (result.exitCode != 0) {
      throw const FormatException('apksigner rejected the APK signature.');
    }
    verifyApkSignerOutput('${result.stdout}\n${result.stderr}', expected);
    stdout.writeln(
      'APK signature and configured certificate fingerprint verified.',
    );
  } on Object catch (error) {
    stderr.writeln('Release APK verification failed: $error');
    exitCode = 1;
  }
}

String findApksigner() {
  final sdkRoots = [
    Platform.environment['ANDROID_SDK_ROOT'],
    Platform.environment['ANDROID_HOME'],
  ].whereType<String>().where((path) => path.isNotEmpty);
  for (final sdkRoot in sdkRoots) {
    final buildTools = Directory('$sdkRoot/build-tools');
    if (!buildTools.existsSync()) continue;
    final candidates =
        buildTools
            .listSync()
            .whereType<Directory>()
            .map((directory) => File('${directory.path}/apksigner'))
            .where(
              (file) =>
                  file.existsSync() &&
                  FileSystemEntity.typeSync(file.path) ==
                      FileSystemEntityType.file,
            )
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    if (candidates.isNotEmpty) return candidates.first.path;
  }
  throw const FormatException(
    'Could not find apksigner. Set ANDROID_SDK_ROOT or ANDROID_HOME to the Android SDK.',
  );
}
