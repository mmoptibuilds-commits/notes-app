import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards README content that is easy to lose in a rewrite: the owner's Orion
/// Store badge, and the no-SDK verification commands, which are executed here
/// against a synthetic release signed with a throwaway key.
void main() {
  final readme = File('README.md').readAsStringSync();

  test('README keeps the Orion Store badge exactly', () {
    const badge =
        '[![Get it on Orion Store](https://raw.githubusercontent.com/'
        'RookieEnough/Orion-Store/refs/heads/main/assets/orion-badge.png)]'
        '(https://rookieenough.github.io/Orion-Data/app/?id=notes-app)';
    expect(readme, contains(badge));
  });

  test('README verification commands accept a genuine release and reject '
      'tampering', () async {
    final temp = await Directory.systemTemp.createTemp('notes-readme-test-');
    addTearDown(() => temp.delete(recursive: true));
    final script = _verifyBlock(readme).replaceAll(
      'notes-1.3.0-linux-x64.tar.gz',
      'notes-1.0.1-linux-x64.tar.gz',
    );

    final archive = File('${temp.path}/notes-1.0.1-linux-x64.tar.gz')
      ..writeAsStringSync('synthetic linux artifact');
    final apk = File('${temp.path}/notes-1.0.1-android-arm64.apk')
      ..writeAsStringSync('synthetic android artifact');
    await _ok('tool/release/keygen.dart', [
      '--key-id', 'test-key', //
      '--private-key', '${temp.path}/private.json',
      '--public-key', '${temp.path}/public.json',
    ]);
    await _ok('tool/release/make_manifest.dart', [
      '--version', '1.0.1', '--build-number', '20261123', //
      '--published-at', '2026-12-01T00:00:00Z',
      '--expires', '2027-06-01T00:00:00Z',
      '--linux', archive.path, '--android', apk.path,
      '--version-code', '20261123',
      '--cert-sha256', 'a' * 64, '--out-dir', temp.path,
    ]);
    await _ok('tool/release/sign_manifest.dart', [
      '--key', '${temp.path}/private.json', '--key-id', 'test-key', //
      '--manifest', '${temp.path}/notes-manifest.json',
      '--sig', '${temp.path}/notes-manifest.json.sig',
    ]);
    final public = jsonDecode(
      File('${temp.path}/public.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    File('${temp.path}/notes-release.pem')
        .writeAsStringSync(_pem(base64.decode(public['publicKey'] as String)));

    Future<ProcessResult> run() => Process.run('bash', [
      '-c',
      'set -e\n$script',
    ], workingDirectory: temp.path);

    final good = await run();
    expect(good.exitCode, 0, reason: '${good.stdout}${good.stderr}');
    expect(good.stdout, contains('Signature Verified Successfully'));
    expect(good.stdout, contains('archive matches the signed manifest'));

    final manifest = File('${temp.path}/notes-manifest.json');
    final original = manifest.readAsStringSync();
    manifest.writeAsStringSync(original.replaceFirst('20261123', '20261124'));
    expect((await run()).exitCode, isNot(0));
    manifest.writeAsStringSync(original);

    archive.writeAsStringSync('tampered', mode: FileMode.append);
    final tampered = await run();
    expect(tampered.exitCode, isNot(0));
    expect(tampered.stdout, isNot(contains('archive matches')));
  }, skip: _opensslSkipReason());
}

String _verifyBlock(String readme) {
  final start = readme.indexOf('### Verify a Linux download');
  expect(start, isNonNegative, reason: 'verification section missing');
  final open = readme.indexOf('```sh\n', start);
  final close = readme.indexOf('```', open + 6);
  return readme.substring(open + 6, close);
}

/// Ed25519 SubjectPublicKeyInfo (RFC 8410) around 32 raw public key bytes.
String _pem(List<int> raw) {
  const prefix = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03];
  final der = [...prefix, 0x21, 0x00, ...raw];
  return '-----BEGIN PUBLIC KEY-----\n${base64.encode(der)}\n'
      '-----END PUBLIC KEY-----\n';
}

Object? _opensslSkipReason() {
  try {
    final r = Process.runSync('openssl', ['version']);
    final m = RegExp(r'OpenSSL (\d+)\.').firstMatch('${r.stdout}');
    if (r.exitCode != 0 || m == null || int.parse(m.group(1)!) < 3) {
      return 'OpenSSL 3 or later not available';
    }
    return null;
  } on ProcessException {
    return 'openssl not installed';
  }
}

Future<void> _ok(String script, List<String> args) async {
  final r = await Process.run('dart', [script, ...args]);
  expect(r.exitCode, 0, reason: '$script: ${r.stderr}');
}
