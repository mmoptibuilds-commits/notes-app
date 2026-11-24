import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../data/models.dart';

/// SHA-256 of the canonical JSON representation of a record's `toJson()`.
/// Object keys are recursively sorted; arrays retain their original order.
String recordDigest(Object record) {
  final json = switch (record) {
    NoteRecord r => r.toJson(),
    FolderRecord r => r.toJson(),
    Map<String, Object?> m => m,
    _ => throw ArgumentError.value(record, 'record', 'unsupported record'),
  };
  return sha256.convert(utf8.encode(jsonEncode(_canonical(json)))).toString();
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonical(value[key]),
    };
  }
  if (value is List) return [for (final item in value) _canonical(item)];
  return value;
}
