import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/update/manifest.dart';
import 'package:notes/update/pinned_keys.dart';

import 'fixtures.dart';

void main() {
  final now = DateTime.utc(2026, 12, 2);

  Future<VerifiedManifest> verify(
    Uint8List bytes,
    Uint8List? sig,
    List<PinnedKey> keys, {
    String version = '1.0.1',
  }) => verifyManifest(
    manifestBytes: bytes,
    signatureBytes: sig,
    keys: keys,
    expectedVersion: version,
    now: now,
  );

  Future<void> expectRejected(
    Future<VerifiedManifest> f, [
    Matcher? message,
  ]) async {
    await expectLater(
      f,
      throwsA(
        isA<ManifestException>().having(
          (e) => e.message,
          'message',
          message ?? isNotEmpty,
        ),
      ),
    );
  }

  test('the release certificate pin equals tool/release_cert_sha256.txt', () {
    final text = File('tool/release_cert_sha256.txt').readAsStringSync();
    expect(kReleaseCertSha256, text.trim().toLowerCase());
  });

  group('production manifest key', () {
    // The one production key. Changing it locks every installed build out of
    // signed updates, so this literal is deliberate.
    const keyId = 'notes-release-1';
    const publicKey = '0Fp4/rw2KnbJD7bt6tA2spIhMTLLFtJwYiEHaivaXzM=';
    const fingerprint =
        '6947c0cb0e4311f7579a37d028f5b5e013326f93935b2b918cacfbd7a0ed0471';

    // Ed25519 SubjectPublicKeyInfo (RFC 8410) around the 32 raw key bytes.
    List<int> spki(String b64) => [
      0x30,
      0x2a,
      0x30,
      0x05,
      0x06,
      0x03,
      0x2b,
      0x65,
      0x70,
      0x03,
      0x21,
      0x00,
      ...base64.decode(b64),
    ];

    test('the app pins exactly notes-release-1', () {
      expect(kPinnedKeys, hasLength(1));
      expect(kPinnedKeys.single.keyId, keyId);
      expect(kPinnedKeys.single.publicKey, publicKey);
      expect(base64.decode(publicKey), hasLength(32));
    });

    test('tool/release_signing_pubkeys.json lists the same keys', () {
      final json = jsonDecode(
        File('tool/release_signing_pubkeys.json').readAsStringSync(),
      ) as List<dynamic>;
      expect(
        json,
        kPinnedKeys
            .map((k) => {'keyId': k.keyId, 'publicKey': k.publicKey})
            .toList(),
      );
    });

    test('README publishes the same PEM key and full fingerprint', () async {
      final der = spki(publicKey);
      final digest = (await Sha256().hash(der)).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(digest, fingerprint);
      final readme = File('README.md').readAsStringSync();
      expect(readme, contains(base64.encode(der)));
      expect(readme, contains(fingerprint));
      expect(readme, contains(keyId));
    });
  });

  group('signed manifests', () {
    test('a correctly signed manifest verifies and parses', () async {
      final s = await TestSigner.create();
      final bytes = encodeManifest(manifestMap());
      final v = await verify(bytes, await s.signFile(bytes), [s.pinned]);
      expect(v.signed, isTrue);
      expect(v.keyId, 'test-key-1');
      expect(v.manifest.version, '1.0.1');
      expect(v.manifest.buildNumber, 20261123);
      final linux = v.manifest.artifactFor('linux', 'x64')!;
      expect(linux.filename, 'notes-1.0.1-linux-x64.tar.gz');
      expect(linux.size, 1000);
      final apk = v.manifest.artifactFor('android', 'arm64')!;
      expect(apk.versionCode, 20261123);
      expect(apk.certSha256, kReleaseCertSha256);
      expect(v.manifest.artifactFor('linux', 'arm64'), isNull);
    });

    test('one changed byte invalidates the signature', () async {
      final s = await TestSigner.create();
      final bytes = encodeManifest(manifestMap());
      final sig = await s.signFile(bytes);
      final tampered = Uint8List.fromList(bytes)..[20] ^= 1;
      await expectRejected(verify(tampered, sig, [s.pinned]));
    });

    test('a signature from another key is rejected', () async {
      final pinned = await TestSigner.create();
      final attacker = await TestSigner.create(); // same keyId, other key
      final bytes = encodeManifest(manifestMap());
      await expectRejected(
        verify(bytes, await attacker.signFile(bytes), [pinned.pinned]),
        contains('does not match'),
      );
    });

    test('an unknown key id is rejected', () async {
      final s = await TestSigner.create();
      final bytes = encodeManifest(manifestMap());
      await expectRejected(
        verify(bytes, await s.signFile(bytes, keyId: 'other'), [s.pinned]),
        contains('unknown key'),
      );
    });

    test('a missing signature is rejected when a key is pinned', () async {
      final s = await TestSigner.create();
      final bytes = encodeManifest(manifestMap());
      await expectRejected(verify(bytes, null, [s.pinned]));
      await expectRejected(verify(bytes, Uint8List(0), [s.pinned]));
    });

    test('an unsupported algorithm is rejected', () async {
      final s = await TestSigner.create();
      final bytes = encodeManifest(manifestMap());
      await expectRejected(
        verify(bytes, await s.signFile(bytes, alg: 'rsa'), [s.pinned]),
        contains('algorithm'),
      );
    });

    test('malformed signature files are rejected', () async {
      final s = await TestSigner.create();
      final bytes = encodeManifest(manifestMap());
      for (final bad in [
        'not json',
        '[]',
        '{"keyId":"test-key-1","alg":"ed25519"}',
        '{"keyId":"test-key-1","alg":"ed25519","signature":"@@@"}',
        '{"keyId":"test-key-1","alg":"ed25519","signature":"AAAA"}',
        '{"keyId":"../x","alg":"ed25519","signature":"AAAA"}',
      ]) {
        await expectRejected(
          verify(bytes, Uint8List.fromList(utf8.encode(bad)), [s.pinned]),
        );
      }
    });

    test('the signature is checked before the manifest is parsed', () async {
      final s = await TestSigner.create();
      final garbage = Uint8List.fromList(utf8.encode('{ not json'));
      // Bad signature on garbage: the error is about the signature, not JSON.
      await expectRejected(
        verify(garbage, await s.signFile(Uint8List(3)), [s.pinned]),
        contains('signature'),
      );
    });

    test('any of several pinned keys may sign', () async {
      final a = await TestSigner.create('key-a');
      final b = await TestSigner.create('key-b');
      final bytes = encodeManifest(manifestMap());
      final v = await verify(bytes, await b.signFile(bytes), [
        a.pinned,
        b.pinned,
      ]);
      expect(v.keyId, 'key-b');
    });
  });

  group('no pinned key', () {
    test('parses but reports the manifest as unsigned', () async {
      final bytes = encodeManifest(manifestMap());
      final v = await verify(bytes, null, const []);
      expect(v.signed, isFalse);
      expect(v.keyId, isNull);
    });

    test('still validates the content', () async {
      final bytes = encodeManifest(
        manifestMap(expires: '2020-01-01T00:00:00Z'),
      );
      await expectRejected(verify(bytes, null, const []));
    });
  });

  group('content validation', () {
    // [label] documents the case at the call site.
    Future<void> rejects(
      String label,
      void Function(Map<String, Object?>) change, [
      Matcher? message,
    ]) async {
      final m = manifestMap();
      change(m);
      await expectRejected(verify(encodeManifest(m), null, const []), message);
    }

    Map<String, Object?> linux(Map<String, Object?> m) =>
        ((m['artifacts']! as List)[0]) as Map<String, Object?>;
    Map<String, Object?> android(Map<String, Object?> m) =>
        ((m['artifacts']! as List)[1]) as Map<String, Object?>;

    test('wrong app, channel, schema', () async {
      await rejects('app', (m) => m['app'] = 'com.other.app');
      await rejects('channel', (m) => m['channel'] = 'beta');
      await rejects('schema', (m) => m['schema'] = 2);
      await rejects('schema type', (m) => m['schema'] = '1');
    });

    test('version must equal the release tag and be a stable semver', () async {
      await rejects('mismatch', (m) => m['version'] = '1.0.2');
      final pre = manifestMap(version: '1.0.1-rc.1');
      await expectRejected(
        verify(encodeManifest(pre), null, const [], version: '1.0.1-rc.1'),
      );
      await rejects('garbage', (m) => m['version'] = 'latest');
      await rejects('number', (m) => m['version'] = 1);
    });

    test('expired manifests are rejected, a later date passes', () async {
      await rejects(
        'expired',
        (m) => m['expires'] = '2026-12-02T00:00:00Z',
        contains('expired'),
      );
      await rejects('local time', (m) => m['expires'] = '2027-06-01T00:00:00');
      await rejects('not a date', (m) => m['expires'] = 'soon');
      final ok = encodeManifest(manifestMap(expires: '2026-12-02T00:00:01Z'));
      expect((await verify(ok, null, const [])).manifest.expires.year, 2026);
    });

    test('build number must be a positive integer', () async {
      await rejects('zero', (m) => m['buildNumber'] = 0);
      await rejects('string', (m) => m['buildNumber'] = '5');
      await rejects('float', (m) => m['buildNumber'] = 1.5);
    });

    test('filename must be the exact expected pattern', () async {
      await rejects(
        'other name',
        (m) => linux(m)['filename'] = 'notes-1.0.1-linux-x64.zip',
      );
      await rejects(
        'path',
        (m) => linux(m)['filename'] = '../notes-1.0.1-linux-x64.tar.gz',
      );
      await rejects(
        'other version',
        (m) => android(m)['filename'] = 'notes-1.0.0-android-arm64.apk',
      );
    });

    test('sha256 must be 64 lowercase hex', () async {
      await rejects('short', (m) => linux(m)['sha256'] = 'abc');
      await rejects('upper', (m) => linux(m)['sha256'] = sha64a.toUpperCase());
      await rejects('non hex', (m) => linux(m)['sha256'] = 'g' * 64);
      await rejects('null', (m) => linux(m)['sha256'] = null);
    });

    test('size must be positive and under the cap', () async {
      await rejects('zero', (m) => linux(m)['size'] = 0);
      await rejects('negative', (m) => linux(m)['size'] = -4);
      await rejects('huge', (m) => linux(m)['size'] = kMaxArtifactBytes + 1);
      await rejects('string', (m) => linux(m)['size'] = '10');
      final edge = manifestMap(linuxSize: kMaxArtifactBytes);
      expect(
        (await verify(
          encodeManifest(edge),
          null,
          const [],
        )).manifest.artifactFor('linux', 'x64')!.size,
        kMaxArtifactBytes,
      );
    });

    test('android entries need a versionCode and a certificate hash', () async {
      await rejects('no code', (m) => android(m).remove('versionCode'));
      await rejects('zero code', (m) => android(m)['versionCode'] = 0);
      await rejects('no cert', (m) => android(m).remove('certSha256'));
      await rejects('bad cert', (m) => android(m)['certSha256'] = 'zz');
    });

    test('a platform listed twice is rejected', () async {
      await rejects('dup', (m) {
        final l = m['artifacts']! as List;
        l.add(Map<String, Object?>.from(l[0] as Map));
      });
    });

    test('unknown platforms are ignored, not trusted', () async {
      final m = manifestMap();
      (m['artifacts']! as List).add({
        'platform': 'windows',
        'arch': 'x64',
        'filename': 'whatever.exe',
        'sha256': 'x',
        'size': -1,
      });
      final v = await verify(encodeManifest(m), null, const []);
      expect(v.manifest.artifacts, hasLength(2));
    });

    test('structural garbage is rejected', () async {
      await expectRejected(verify(Uint8List.fromList([0xff, 0xfe]), null, []));
      await expectRejected(
        verify(Uint8List.fromList(utf8.encode('[]')), null, []),
      );
      await rejects('artifacts', (m) => m['artifacts'] = 'x');
      await rejects('entry', (m) => m['artifacts'] = [1]);
    });
  });
}
