import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:notes/update/pinned_keys.dart';

/// A throwaway signing identity for tests. Never a real key.
class TestSigner {
  TestSigner._(this.keyId, this._pair, this.publicKeyBytes);

  final String keyId;
  final SimpleKeyPair _pair;
  final List<int> publicKeyBytes;

  static Future<TestSigner> create([String keyId = 'test-key-1']) async {
    final pair = await Ed25519().newKeyPair();
    final pub = await pair.extractPublicKey();
    return TestSigner._(keyId, pair, pub.bytes);
  }

  PinnedKey get pinned =>
      PinnedKey(keyId: keyId, publicKey: base64.encode(publicKeyBytes));

  Future<Uint8List> signFile(
    Uint8List manifest, {
    String? keyId,
    String alg = 'ed25519',
  }) async {
    final sig = await Ed25519().sign(manifest, keyPair: _pair);
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'keyId': keyId ?? this.keyId,
          'alg': alg,
          'signature': base64.encode(sig.bytes),
        }),
      ),
    );
  }
}

const sha64a =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const sha64b =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// A schema 1 manifest as a map, so tests can break one field at a time.
Map<String, Object?> manifestMap({
  String version = '1.0.1',
  int build = 20261123,
  String expires = '2027-06-01T00:00:00Z',
  String linuxSha = sha64a,
  int linuxSize = 1000,
  String apkSha = sha64b,
  int apkSize = 2000,
  int? versionCode,
  String? certSha,
}) => {
  'schema': 1,
  'app': 'com.mmoptibuilds.notes',
  'channel': 'stable',
  'version': version,
  'buildNumber': build,
  'publishedAt': '2026-12-01T00:00:00Z',
  'expires': expires,
  'artifacts': <Object?>[
    <String, Object?>{
      'platform': 'linux',
      'arch': 'x64',
      'filename': 'notes-$version-linux-x64.tar.gz',
      'sha256': linuxSha,
      'size': linuxSize,
    },
    <String, Object?>{
      'platform': 'android',
      'arch': 'arm64',
      'filename': 'notes-$version-android-arm64.apk',
      'sha256': apkSha,
      'size': apkSize,
      'versionCode': versionCode ?? build,
      'certSha256': certSha ?? kReleaseCertSha256,
    },
  ],
};

Uint8List encodeManifest(Map<String, Object?> m) =>
    Uint8List.fromList(utf8.encode('${jsonEncode(m)}\n'));
