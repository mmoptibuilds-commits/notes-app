import 'dart:convert';
import 'dart:io';

import 'release_common.dart';

Future<void> main(List<String> argv) async {
  try {
    final args = parseArgs(argv);
    final keyId = required(args, 'key-id');
    final manifest = await File(required(args, 'manifest')).readAsBytes();
    final key = await readPrivateKey(
      File(required(args, 'key')),
      expectedKeyId: keyId,
    );
    final signature = await algorithm.sign(manifest, keyPair: key);
    await writeText(
      File(required(args, 'sig')),
      canonicalJson({
        'keyId': keyId,
        'alg': 'ed25519',
        'signature': base64.encode(signature.bytes),
      }),
    );
  } on Object catch (error) {
    stderr.writeln('sign_manifest: $error');
    exitCode = 2;
  }
}
