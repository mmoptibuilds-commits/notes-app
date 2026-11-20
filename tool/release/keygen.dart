import 'dart:convert';
import 'dart:io';

import 'release_common.dart';

Future<void> main(List<String> argv) async {
  try {
    final args = parseArgs(argv);
    final keyId = required(args, 'key-id');
    final privatePath = required(args, 'private-key');
    final publicPath = required(args, 'public-key');
    if (await File(privatePath).exists() || await File(publicPath).exists()) {
      throw const FileSystemException(
        'Refusing to overwrite an existing key file',
      );
    }
    final pair = await algorithm.newKeyPair();
    final extracted = await pair.extract();
    final seed = await extracted.extractPrivateKeyBytes();
    final privateFile = File(privatePath);
    await privateFile.parent.create(recursive: true);
    await privateFile.create(exclusive: true);
    final chmod = await Process.run('chmod', ['600', privatePath]);
    if (chmod.exitCode != 0) {
      throw StateError('Could not set private key mode 0600');
    }
    await writeText(
      privateFile,
      canonicalJson({
        'keyId': keyId,
        'seed': base64.encode(seed),
        'publicKey': base64.encode(extracted.publicKey.bytes),
      }),
    );
    await writeText(
      File(publicPath),
      canonicalJson({
        'keyId': keyId,
        'publicKey': base64.encode(extracted.publicKey.bytes),
      }),
    );
    stdout.writeln('Created Ed25519 keypair. Keep the private key offline.');
  } on Object catch (error) {
    stderr.writeln('keygen: $error');
    exitCode = 2;
  }
}
