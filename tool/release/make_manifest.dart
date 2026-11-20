import 'dart:io';

import 'release_common.dart';

Future<void> main(List<String> argv) async {
  try {
    final args = parseArgs(argv);
    final version = required(args, 'version');
    final build = int.parse(required(args, 'build-number'));
    final publishedText = required(args, 'published-at');
    final expiresText = required(args, 'expires');
    if (!publishedText.endsWith('Z') || !expiresText.endsWith('Z')) {
      throw const FormatException(
        'published-at and expires must use UTC Z timestamps',
      );
    }
    final published = DateTime.parse(publishedText).toUtc();
    final expires = DateTime.parse(expiresText).toUtc();
    final linux = File(required(args, 'linux'));
    final android = File(required(args, 'android'));
    final versionCode = int.parse(required(args, 'version-code'));
    final cert = required(args, 'cert-sha256');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        build <= 0 ||
        versionCode <= 0 ||
        versionCode != build ||
        !isSha256(cert) ||
        !expires.isAfter(published)) {
      throw const FormatException(
        'Invalid version, build number, certificate hash, or dates',
      );
    }
    for (final file in [linux, android]) {
      if (!await file.exists()) {
        throw FormatException('Artifact does not exist: ${file.path}');
      }
    }
    if (linux.uri.pathSegments.last != 'notes-$version-linux-x64.tar.gz' ||
        android.uri.pathSegments.last != 'notes-$version-android-arm64.apk') {
      throw const FormatException(
        'Artifact filenames must match the release naming convention',
      );
    }
    final manifest = <String, Object?>{
      'schema': 1,
      'app': 'com.mmoptibuilds.notes',
      'channel': 'stable',
      'version': version,
      'buildNumber': build,
      'publishedAt': published.toIso8601String().replaceFirst('.000Z', 'Z'),
      'expires': expires.toIso8601String().replaceFirst('.000Z', 'Z'),
      'artifacts': [
        {
          'platform': 'linux',
          'arch': 'x64',
          'filename': 'notes-$version-linux-x64.tar.gz',
          'sha256': await sha256File(linux),
          'size': await linux.length(),
        },
        {
          'platform': 'android',
          'arch': 'arm64',
          'filename': 'notes-$version-android-arm64.apk',
          'sha256': await sha256File(android),
          'size': await android.length(),
          'versionCode': versionCode,
          'certSha256': cert.toLowerCase(),
        },
      ],
    };
    final output = Directory(args['out-dir'] ?? '.');
    await writeText(
      File('${output.path}/notes-manifest.json'),
      canonicalJson(manifest),
    );
  } on Object catch (error) {
    stderr.writeln('make_manifest: $error');
    exitCode = 2;
  }
}
