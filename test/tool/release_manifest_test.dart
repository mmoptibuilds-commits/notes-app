import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late File linux;
  late File android;
  late File privateKey;
  late File publicKey;
  late File manifest;
  late File signature;
  late File pubkeys;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('notes-manifest-test-');
    linux = File('${temp.path}/notes-1.0.1-linux-x64.tar.gz')
      ..writeAsStringSync('synthetic linux artifact');
    android = File('${temp.path}/notes-1.0.1-android-arm64.apk')
      ..writeAsStringSync('synthetic android artifact');
    privateKey = File('${temp.path}/private.json');
    publicKey = File('${temp.path}/public.json');
    manifest = File('${temp.path}/notes-manifest.json');
    signature = File('${temp.path}/notes-manifest.json.sig');
    pubkeys = File('${temp.path}/pubkeys.json');
    final result = await _dart('tool/release/keygen.dart', [
      '--key-id',
      'test-key',
      '--private-key',
      privateKey.path,
      '--public-key',
      publicKey.path,
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final key =
        jsonDecode(publicKey.readAsStringSync()) as Map<String, dynamic>;
    pubkeys.writeAsStringSync(jsonEncode([key]));
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<void> makeAndSign() async {
    final generated = await _dart('tool/release/make_manifest.dart', [
      '--version',
      '1.0.1',
      '--build-number',
      '20261123',
      '--published-at',
      '2026-12-01T00:00:00Z',
      '--expires',
      '2027-06-01T00:00:00Z',
      '--linux',
      linux.path,
      '--android',
      android.path,
      '--version-code',
      '20261123',
      '--cert-sha256',
      List.filled(64, 'a').join(),
      '--out-dir',
      temp.path,
    ]);
    expect(generated.exitCode, 0, reason: generated.stderr.toString());
    final signed = await _dart('tool/release/sign_manifest.dart', [
      '--key',
      privateKey.path,
      '--key-id',
      'test-key',
      '--manifest',
      manifest.path,
      '--sig',
      signature.path,
    ]);
    expect(signed.exitCode, 0, reason: signed.stderr.toString());
  }

  Future<ProcessResult> verify() => _dart('tool/release/verify_manifest.dart', [
    '--pubkeys',
    pubkeys.path,
    manifest.path,
    signature.path,
  ]);

  test(
    'manifest generation is canonical and Ed25519 signature verifies',
    () async {
      await makeAndSign();
      final bytes = manifest.readAsBytesSync();
      expect(bytes.last, 10);
      expect(utf8.decode(bytes), isNot(contains(': ')));
      expect(jsonDecode(utf8.decode(bytes))['artifacts'], hasLength(2));
      expect((await verify()).exitCode, 0);
    },
  );

  test('tampering, a wrong key, and bad signature are rejected', () async {
    await makeAndSign();
    final original = manifest.readAsBytesSync();
    manifest.writeAsBytesSync([...original, 32]);
    expect((await verify()).exitCode, isNot(0));
    manifest.writeAsBytesSync(original);
    signature.writeAsStringSync(
      '{"keyId":"test-key","alg":"ed25519","signature":"${base64.encode(List.filled(64, 0))}"}',
    );
    expect((await verify()).exitCode, isNot(0));
    pubkeys.writeAsStringSync('[]');
    expect((await verify()).exitCode, isNot(0));
  });

  test('signing refuses a group-readable private key', () async {
    await makeAndSign();
    Process.runSync('chmod', ['644', privateKey.path]);
    final result = await _dart('tool/release/sign_manifest.dart', [
      '--key',
      privateKey.path,
      '--key-id',
      'test-key',
      '--manifest',
      manifest.path,
      '--sig',
      '${temp.path}/refused.sig',
    ]);
    expect(result.exitCode, isNot(0));
  });
}

Future<ProcessResult> _dart(String script, List<String> args) => Process.run(
  'dart',
  [script, ...args],
  workingDirectory: Directory.current.path,
);
