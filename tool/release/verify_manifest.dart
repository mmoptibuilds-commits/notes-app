import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'release_common.dart';

Future<void> main(List<String> argv) async {
  try {
    const usage =
        'usage: verify_manifest.dart --pubkeys PUBKEYS '
        '(--artifact FILE ... | --manifest-only) MANIFEST SIGNATURE';
    if (argv.length < 4 || argv[0] != '--pubkeys') {
      throw const FormatException(usage);
    }
    final artifactPaths = <String>[];
    var manifestOnly = false;
    final positional = <String>[];
    for (var i = 2; i < argv.length; i++) {
      if (argv[i] == '--artifact') {
        if (i + 1 >= argv.length) {
          throw const FormatException(usage);
        }
        artifactPaths.add(argv[++i]);
      } else if (argv[i] == '--manifest-only') {
        manifestOnly = true;
      } else {
        positional.add(argv[i]);
      }
    }
    if (positional.length != 2 ||
        (artifactPaths.isEmpty && !manifestOnly) ||
        (artifactPaths.isNotEmpty && manifestOnly)) {
      throw const FormatException(usage);
    }
    final keysJson =
        jsonDecode(await File(argv[1]).readAsString()) as List<dynamic>;
    final manifestBytes = await File(positional[0]).readAsBytes();
    final sig = jsonDecode(
      await File(positional[1]).readAsString(),
    ) as Map<String, dynamic>;
    if (sig['alg'] != 'ed25519') {
      throw const FormatException('Unsupported signature algorithm');
    }
    final entry = keysJson.cast<Map<String, dynamic>>().firstWhere(
      (key) => key['keyId'] == sig['keyId'],
      orElse: () => throw const FormatException('Unknown signing key id'),
    );
    final publicBytes = base64.decode(entry['publicKey'] as String);
    final signatureBytes = base64.decode(sig['signature'] as String);
    if (publicBytes.length != 32 || signatureBytes.length != 64) {
      throw const FormatException('Invalid Ed25519 key or signature length');
    }
    final valid = await algorithm.verify(
      manifestBytes,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) throw const FormatException('Manifest signature is invalid');
    final manifest =
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    if (manifest['schema'] != 1 ||
        manifest['app'] != 'com.mmoptibuilds.notes' ||
        manifest['channel'] != 'stable' ||
        manifest['artifacts'] is! List) {
      throw const FormatException(
        'Manifest schema, app, channel, or artifacts invalid',
      );
    }
    final version = manifest['version'];
    final buildNumber = manifest['buildNumber'];
    if (version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        buildNumber is! int ||
        buildNumber <= 0) {
      throw const FormatException('Manifest version or build number invalid');
    }
    final artifacts = (manifest['artifacts'] as List)
        .cast<Map<String, dynamic>>();
    if (artifacts.length != 2) {
      throw const FormatException('Expected Linux and Android artifacts');
    }
    final linux = artifacts
        .where((item) => item['platform'] == 'linux')
        .toList();
    final android = artifacts
        .where((item) => item['platform'] == 'android')
        .toList();
    if (linux.length != 1 ||
        android.length != 1 ||
        linux.single['arch'] != 'x64' ||
        android.single['arch'] != 'arm64' ||
        linux.single['filename'] != 'notes-$version-linux-x64.tar.gz' ||
        android.single['filename'] != 'notes-$version-android-arm64.apk' ||
        android.single['versionCode'] != buildNumber ||
        !isSha256(android.single['certSha256'] as String? ?? '')) {
      throw const FormatException('Artifact platform metadata invalid');
    }
    for (final artifact in artifacts) {
      if (!isSha256(artifact['sha256'] as String? ?? '') ||
          artifact['size'] is! int ||
          (artifact['size'] as int) <= 0) {
        throw const FormatException('Artifact checksum or size invalid');
      }
    }
    final expiry = DateTime.parse(manifest['expires'] as String).toUtc();
    if (!expiry.isAfter(DateTime.now().toUtc())) {
      throw const FormatException('Manifest is expired');
    }
    // The signature only protects the manifest. Installing is safe only if the
    // file you hold is the one the manifest describes, so check the bytes.
    for (final path in artifactPaths) {
      final file = File(path);
      final name = path.split(Platform.pathSeparator).last;
      final listed = artifacts.where((a) => a['filename'] == name).toList();
      if (listed.length != 1) {
        throw FormatException('$name is not listed in the signed manifest');
      }
      if (!await file.exists()) throw FormatException('$name does not exist');
      final size = await file.length();
      if (size != listed.single['size']) {
        throw FormatException(
          '$name has $size bytes but the signed manifest says '
          '${listed.single['size']}',
        );
      }
      final digest = await sha256File(file);
      if (digest != (listed.single['sha256'] as String).toLowerCase()) {
        throw FormatException(
          '$name does not match the signed SHA-256: do not install it',
        );
      }
      stdout.writeln('Artifact verified: $name ($size bytes, sha256 $digest)');
    }
    stdout.writeln('Manifest signature and schema verified (${sig['keyId']}).');
  } on Object catch (error) {
    stderr.writeln('verify_manifest: $error');
    exitCode = 1;
  }
}
