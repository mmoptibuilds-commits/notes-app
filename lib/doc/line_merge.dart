import 'dart:convert';

import 'delta_text.dart';

/// Result of merging two Delta documents against a common base.
class LineMergeResult {
  const LineMergeResult.merged(this.body) : isConflict = false;
  const LineMergeResult.conflict() : body = null, isConflict = true;

  final String? body;
  final bool isConflict;
}

/// Performs a bounded diff3 merge over canonical Quill Delta lines.
///
/// The LCS table is capped at 1,000,000 cells after common prefixes and
/// suffixes are removed. Larger divergent regions return conflict promptly;
/// this keeps pathological 1 MB documents from consuming unbounded time or
/// memory while still making small edits to large documents cheap.
LineMergeResult mergeBodies(String base, String local, String remote) {
  try {
    if (base == local && local == remote) {
      // Validate once, then retain the original valid encoding. Besides being
      // lossless for opaque embeds, this keeps very large unchanged documents
      // from being decoded and re-encoded three times.
      _lines(local);
      return LineMergeResult.merged(local);
    }
    final b = _lines(base);
    final l = _lines(local);
    final r = _lines(remote);
    if (_sameLines(l, r)) return LineMergeResult.merged(_serialize(l));
    if (_sameLines(b, l)) return LineMergeResult.merged(_serialize(r));
    if (_sameLines(b, r)) return LineMergeResult.merged(_serialize(l));
    final left = _diff(b, l);
    final right = _diff(b, r);
    if (left == null || right == null) return const LineMergeResult.conflict();

    final all = <_Hunk>[];
    var leftIndex = 0;
    var rightIndex = 0;
    while (leftIndex < left.length && rightIndex < right.length) {
      final a = left[leftIndex];
      final c = right[rightIndex];
      if (_sameHunk(a, c)) {
        all.add(a);
        leftIndex++;
        rightIndex++;
      } else if (_overlap(a, c)) {
        return const LineMergeResult.conflict();
      } else if (_comesBefore(a, c)) {
        all.add(a);
        leftIndex++;
      } else {
        all.add(c);
        rightIndex++;
      }
    }
    all.addAll(left.skip(leftIndex));
    all.addAll(right.skip(rightIndex));
    all.sort((a, b) {
      final start = a.start.compareTo(b.start);
      if (start != 0) return start;
      final end = a.end.compareTo(b.end);
      if (end != 0) return end;
      return _replacementKey(a.replacement)
          .compareTo(_replacementKey(b.replacement));
    });

    final output = <_Line>[];
    var cursor = 0;
    for (final hunk in all) {
      if (hunk.start < cursor) return const LineMergeResult.conflict();
      for (var i = cursor; i < hunk.start; i++) {
        output.add(b[i]);
      }
      output.addAll(hunk.replacement);
      cursor = hunk.end;
    }
    for (var i = cursor; i < b.length; i++) {
      output.add(b[i]);
    }
    if (output.isEmpty || !output.last.endsWithNewline) {
      return const LineMergeResult.conflict();
    }
    final ops = <Map<String, dynamic>>[];
    for (final line in output) {
      ops.addAll(line.ops);
    }
    return LineMergeResult.merged(jsonEncode(_canonical(_coalesce(ops))));
  } on Object {
    // Bad or non-canonical peer data must never prevent sync from converging.
    return const LineMergeResult.conflict();
  }
}

bool _sameLines(List<_Line> a, List<_Line> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].key != b[i].key) return false;
  }
  return true;
}

String _serialize(List<_Line> lines) =>
    jsonEncode(_canonical(_coalesce([for (final line in lines) ...line.ops])));

class _Line {
  const _Line(this.ops, this.key, this.endsWithNewline);
  final List<Map<String, dynamic>> ops;
  final String key;
  final bool endsWithNewline;
}

class _Hunk {
  const _Hunk(this.start, this.end, this.replacement);
  final int start;
  final int end;
  final List<_Line> replacement;
}

List<_Line> _lines(String body) {
  final ops = decodeOps(body);
  final result = <_Line>[];
  var current = <Map<String, dynamic>>[];
  for (final op in ops) {
    if (!op.containsKey('insert')) {
      throw const FormatException('Not a document Delta');
    }
    final data = op['insert'];
    final attrs = op['attributes'];
    if (attrs != null && attrs is! Map) {
      throw const FormatException('Invalid Delta attributes');
    }
    if (data is String) {
      var start = 0;
      while (true) {
        final newline = data.indexOf('\n', start);
        if (newline < 0) {
          if (start < data.length) {
            current.add(_op(data.substring(start), attrs));
          }
          break;
        }
        if (newline > start) {
          current.add(_op(data.substring(start, newline), attrs));
        }
        current.add(_op('\n', attrs));
        result.add(_makeLine(current));
        current = <Map<String, dynamic>>[];
        start = newline + 1;
      }
    } else if (data is Map) {
      current.add(_op(data, attrs));
    } else {
      throw const FormatException('Invalid Delta insert');
    }
  }
  if (current.isNotEmpty) {
    throw const FormatException('Delta lacks final newline');
  }
  if (result.isEmpty) throw const FormatException('Empty Delta');
  return result;
}

Map<String, dynamic> _op(Object data, Object? attrs) => {
  'insert': data,
  if (attrs != null && (attrs as Map).isNotEmpty) 'attributes': attrs,
};

_Line _makeLine(List<Map<String, dynamic>> ops) {
  final frozen = List<Map<String, dynamic>>.unmodifiable(ops);
  return _Line(frozen, jsonEncode(_canonical(frozen)), true);
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

List<Map<String, dynamic>> _coalesce(List<Map<String, dynamic>> ops) {
  final out = <Map<String, dynamic>>[];
  for (final op in ops) {
    if (op['insert'] is String && (op['insert'] as String).isEmpty) continue;
    if (out.isNotEmpty &&
        out.last['insert'] is String &&
        op['insert'] is String &&
        jsonEncode(_canonical(out.last['attributes'])) ==
            jsonEncode(_canonical(op['attributes']))) {
      out[out.length - 1] = {
        'insert': '${out.last['insert']}${op['insert']}',
        if (op['attributes'] != null) 'attributes': op['attributes'],
      };
    } else {
      out.add(op);
    }
  }
  return out;
}

String _replacementKey(List<_Line> lines) =>
    lines.map((l) => l.key).join('\u0000');

bool _sameHunk(_Hunk a, _Hunk b) =>
    a.start == b.start &&
    a.end == b.end &&
    _replacementKey(a.replacement) == _replacementKey(b.replacement);

bool _comesBefore(_Hunk a, _Hunk b) {
  if (a.start != b.start) return a.start < b.start;
  return a.end < b.end;
}

bool _overlap(_Hunk a, _Hunk b) {
  final aInsert = a.start == a.end;
  final bInsert = b.start == b.end;
  if (aInsert && bInsert) return a.start == b.start;
  if (aInsert) return a.start > b.start && a.start < b.end;
  if (bInsert) return b.start > a.start && b.start < a.end;
  return a.start < b.end && b.start < a.end;
}

/// Returns LCS-derived base-coordinate hunks, or null when the bounded table
/// would exceed the documented guard.
List<_Hunk>? _diff(List<_Line> base, List<_Line> changed) {
  var prefix = 0;
  while (prefix < base.length &&
      prefix < changed.length &&
      base[prefix].key == changed[prefix].key) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < base.length - prefix &&
      suffix < changed.length - prefix &&
      base[base.length - 1 - suffix].key ==
          changed[changed.length - 1 - suffix].key) {
    suffix++;
  }
  final n = base.length - prefix - suffix;
  final m = changed.length - prefix - suffix;
  if (n == 0 && m == 0) return <_Hunk>[];
  if (n * m > 1000000) return null;
  final dp = List<List<int>>.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = base[prefix + i].key == changed[prefix + j].key
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final hunks = <_Hunk>[];
  var i = 0;
  var j = 0;
  var start = -1;
  var end = -1;
  var replacement = <_Line>[];
  void finish() {
    if (start >= 0) hunks.add(_Hunk(start, end, replacement));
    start = -1;
    replacement = <_Line>[];
  }

  while (i < n || j < m) {
    if (i < n && j < m && base[prefix + i].key == changed[prefix + j].key) {
      finish();
      i++;
      j++;
      continue;
    }
    if (start < 0) {
      start = prefix + i;
      end = start;
    }
    if (j < m && (i == n || dp[i][j + 1] >= dp[i + 1][j])) {
      replacement.add(changed[prefix + j]);
      j++;
    } else {
      i++;
      end = prefix + i;
    }
  }
  finish();
  return hunks;
}
