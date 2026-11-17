import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _rng = Random.secure();

Uint8List randomBytes(int n) =>
    Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _uuidFromBytes(List<int> b) {
  final h = hex(b.sublist(0, 16));
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Random RFC 4122 version-4 UUID.
String newId() {
  final b = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  return _uuidFromBytes(b);
}

/// Stable UUID-shaped id derived from [parts]. The same parts give the same id
/// on every device, which is what makes independent imports and independently
/// detected conflicts converge instead of duplicating.
String derivedId(String namespace, List<String> parts) {
  final digest = sha256.convert(
    utf8.encode([namespace, ...parts].join('\u0000')),
  );
  final b = Uint8List.fromList(digest.bytes.sublist(0, 16));
  b[6] = (b[6] & 0x0f) | 0x80; // version nibble 8: custom, per RFC 9562
  b[8] = (b[8] & 0x3f) | 0x80;
  return _uuidFromBytes(b);
}

/// Random 64-bit device id, 16 hex characters.
String newDeviceId() => hex(randomBytes(8));

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

String sha256OfString(String s) => sha256Hex(utf8.encode(s));
