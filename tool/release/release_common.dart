import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

final algorithm = Ed25519();

String canonicalJson(Object? value) => '${jsonEncode(_sort(value))}\n';

Object? _sort(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{for (final key in keys) key: _sort(value[key])};
  }
  if (value is List) return value.map(_sort).toList();
  return value;
}

Future<String> sha256File(File file) async {
  final digest = await Sha256().hash(await file.readAsBytes());
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

bool isSha256(String value) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

Future<SimpleKeyPairData> readPrivateKey(
  File file, {
  String? expectedKeyId,
}) async {
  final stat = await file.stat();
  if ((stat.mode & 0x24) != 0) {
    throw FormatException('Private key file must not be group/world-readable');
  }
  final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  if (expectedKeyId != null && map['keyId'] != expectedKeyId) {
    throw const FormatException('Private key id does not match --key-id');
  }
  final seed = base64.decode(map['seed'] as String);
  final publicBytes = base64.decode(map['publicKey'] as String);
  if (seed.length != 32 || publicBytes.length != 32) {
    throw const FormatException('Expected 32-byte Ed25519 seed and public key');
  }
  return SimpleKeyPairData(
    seed,
    publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
    type: KeyPairType.ed25519,
  );
}

Future<void> writeText(File file, String text) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(text, flush: true);
}

Map<String, String> parseArgs(
  List<String> args, {
  Set<String> flags = const {},
}) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      throw FormatException('Unexpected argument: $arg');
    }
    final name = arg.substring(2);
    if (flags.contains(name)) {
      result[name] = 'true';
    } else {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        throw FormatException('Missing value for $arg');
      }
      result[name] = args[++i];
    }
  }
  return result;
}

String required(Map<String, String> args, String key) =>
    args[key] ?? (throw FormatException('Missing --$key'));
