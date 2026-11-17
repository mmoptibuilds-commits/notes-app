import 'dart:convert';

enum VvOrder { equal, dominates, dominated, concurrent }

/// Version vector: for each writer, how many writes of theirs are included.
///
/// Immutable. Used to tell "newer" from "edited independently".
class VersionVector {
  VersionVector([Map<String, int> counters = const {}])
    : _c = Map.unmodifiable(
        Map.fromEntries(
          counters.entries.where((e) => e.value > 0).toList()
            ..sort((a, b) => a.key.compareTo(b.key)),
        ),
      );

  final Map<String, int> _c;

  static final empty = VersionVector();

  factory VersionVector.decode(String json) {
    final raw = jsonDecode(json);
    if (raw is! Map) throw FormatException('Malformed version vector', json);
    return VersionVector({
      for (final e in raw.entries) e.key as String: (e.value as num).toInt(),
    });
  }

  /// Canonical JSON (keys sorted), safe to compare and hash as text.
  String encode() => jsonEncode(_c);

  Map<String, int> get counters => _c;

  int operator [](String node) => _c[node] ?? 0;

  VersionVector increment(String node) =>
      VersionVector({..._c, node: this[node] + 1});

  /// Pointwise maximum.
  VersionVector merge(VersionVector other) {
    final out = Map<String, int>.of(_c);
    other._c.forEach((k, v) {
      if (v > (out[k] ?? 0)) out[k] = v;
    });
    return VersionVector(out);
  }

  VvOrder compare(VersionVector other) {
    var greater = false;
    var less = false;
    for (final k in {..._c.keys, ...other._c.keys}) {
      final a = this[k];
      final b = other[k];
      if (a > b) greater = true;
      if (a < b) less = true;
    }
    if (greater && less) return VvOrder.concurrent;
    if (greater) return VvOrder.dominates;
    if (less) return VvOrder.dominated;
    return VvOrder.equal;
  }

  @override
  bool operator ==(Object other) =>
      other is VersionVector && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => encode();
}
