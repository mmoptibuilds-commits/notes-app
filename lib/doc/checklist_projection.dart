import 'dart:convert';

import 'package:dart_quill_delta/dart_quill_delta.dart';

/// Parses a stored body (op array, or `{"ops": [...]}`) into a [Delta].
Delta deltaFromBody(String bodyJson) {
  final raw = jsonDecode(bodyJson);
  final ops = raw is Map ? raw['ops'] : raw;
  if (ops is! List) throw const FormatException('Body is not a Delta');
  return Delta.fromJson(ops);
}

String bodyFromDelta(Delta delta) => jsonEncode(delta.toJson());

/// Length of a document in characters (an embed counts as one).
/// Not `Delta.length`, which is the number of operations.
int documentLength(Delta delta) {
  var n = 0;
  for (final op in delta.toList()) {
    n += op.length ?? 0;
  }
  return n;
}

/// A checked checklist line held outside the visible document.
class CompletedLine {
  CompletedLine._(this.id, this.delta, this.anchor);

  /// Id of the line that preceded this one when it was last removed, so
  /// [ChecklistProjection.putBack] can restore the exact order even among
  /// lines that share an anchor.
  int? _prevId;

  /// Stable for the life of the projection; use as a widget key.
  final int id;

  /// The whole line exactly as stored, ending in its newline op, with every
  /// attribute intact.
  final Delta delta;

  /// Offset in the visible document where this line belongs: always the start
  /// of a visible line, or the document end.
  int anchor;

  int get length => documentLength(delta);

  /// The line's text without the newline; embeds are skipped.
  String get text {
    final b = StringBuffer();
    for (final op in delta.toList()) {
      final d = op.data;
      if (d is String) b.write(d);
    }
    final s = b.toString();
    return s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
  }
}

/// Shows a document without its checked checklist lines, without ever
/// changing what is stored.
///
/// The stored ("canonical") document keeps every line where it is. [split]
/// separates it into the visible document the editor works on and the list of
/// [completed] lines. Each completed line remembers where it belongs through
/// an anchor that is moved along as the visible document is edited
/// ([transformBy]). [merge] puts the lines back at their anchors.
///
/// For any document `d`: `merge(split(d).visible)` equals `d`.
class ChecklistProjection {
  ChecklistProjection._(this._completed, this._syntheticTail)
    : _nextId = _completed.length;

  final List<CompletedLine> _completed;

  /// True when the visible document's only line was invented because every
  /// stored line was checked (a document cannot be empty).
  bool _syntheticTail;
  int _nextId;

  /// Completed lines in document order.
  List<CompletedLine> get completed => List.unmodifiable(_completed);

  bool get isEmpty => _completed.isEmpty;

  /// Splits [canonical] into the visible document and its projection.
  static ({Delta visible, ChecklistProjection projection}) split(
    Delta canonical,
  ) {
    final lines = _linesOf(canonical);
    if (!lines.any((l) => l.checked)) {
      return (
        visible: Delta.from(canonical),
        projection: ChecklistProjection._([], false),
      );
    }
    var visible = Delta();
    var visibleLength = 0;
    final completed = <CompletedLine>[];
    for (final l in lines) {
      final slice = canonical.slice(l.start, l.end);
      if (l.checked) {
        completed.add(CompletedLine._(completed.length, slice, visibleLength));
      } else {
        visible = visible.concat(slice);
        visibleLength += l.length;
      }
    }
    final synthetic = visible.isEmpty;
    if (synthetic) visible = Delta()..insert('\n');
    return (
      visible: visible,
      projection: ChecklistProjection._(completed, synthetic),
    );
  }

  /// The canonical document for the current [visible] document.
  Delta merge(Delta visible) {
    if (_completed.isEmpty) return Delta.from(visible);
    var out = Delta();
    if (_syntheticTail && _isBareNewline(visible)) {
      for (final c in _completed) {
        out = out.concat(c.delta);
      }
      return out;
    }
    final starts = _lineStarts(visible);
    final end = documentLength(visible);
    var pos = 0;
    for (final c in _completed) {
      final at = _snap(starts, c.anchor, end);
      if (at > pos) {
        out = out.concat(visible.slice(pos, at));
        pos = at;
      }
      out = out.concat(c.delta);
    }
    if (pos < end) out = out.concat(visible.slice(pos));
    return out;
  }

  /// Follows an edit the user made to the visible document.
  ///
  /// Do not call this for the changes returned by [extractChecked] or
  /// [restore]; those already account for themselves.
  void transformBy(Delta change) {
    for (final c in _completed) {
      c.anchor = change.transformPosition(c.anchor, force: false);
    }
  }

  /// Whether [change] could have produced a checked line in the visible
  /// document. Cheap; use it to decide whether to call [extractChecked].
  static bool mayCheck(Delta change) =>
      change.toList().any((op) => op.attributes?['list'] == 'checked');

  /// Moves every checked line of [visible] into [completed].
  ///
  /// Returns the change to apply to the visible document (it removes those
  /// lines), or null when there is nothing checked.
  Delta? extractChecked(Delta visible) {
    final lines = _linesOf(visible);
    final checked = [
      for (final l in lines)
        if (l.checked) l,
    ];
    if (checked.isEmpty) return null;
    final takesAll = checked.length == lines.length;

    final change = Delta();
    var cursor = 0;
    var removed = 0;
    final fresh = <(int oldStart, CompletedLine line)>[];
    for (var i = 0; i < checked.length; i++) {
      final l = checked[i];
      final line = CompletedLine._(
        _nextId++,
        visible.slice(l.start, l.end),
        l.start - removed,
      );
      fresh.add((l.start, line));
      if (l.start > cursor) change.retain(l.start - cursor);
      if (takesAll && i == checked.length - 1) {
        // A document cannot be empty: keep the last newline, stripped of its
        // block formatting, as a placeholder line.
        if (l.length > 1) change.delete(l.length - 1);
        change.retain(1, {for (final k in l.attributes.keys) k: null});
        removed += l.length - 1;
        _syntheticTail = true;
      } else {
        change.delete(l.length);
        removed += l.length;
      }
      cursor = l.end;
    }

    // Order by position in the old visible document. An existing line anchored
    // at a position comes before the visible line that started there.
    final merged = <(int pos, int kind, CompletedLine line)>[
      for (final c in _completed) (c.anchor, 0, c),
      for (final f in fresh) (f.$1, 1, f.$2),
    ];
    final order = List.generate(merged.length, (i) => i)
      ..sort((a, b) {
        final byPos = merged[a].$1.compareTo(merged[b].$1);
        if (byPos != 0) return byPos;
        final byKind = merged[a].$2.compareTo(merged[b].$2);
        return byKind != 0 ? byKind : a.compareTo(b);
      });
    for (final c in _completed) {
      c.anchor = change.transformPosition(c.anchor, force: false);
    }
    _completed
      ..clear()
      ..addAll([for (final i in order) merged[i].$3]);
    return change;
  }

  /// Puts the completed lines with [ids] back into the visible document as
  /// unchecked items, each at its own place.
  ///
  /// Returns the change to apply to [visible], or null if no id matched.
  /// A line struck through from end to end (the legacy app struck items when
  /// checking them) loses the strike-through; nothing else is altered.
  Delta? restore(Iterable<int> ids, Delta visible) {
    final wanted = ids.toSet();
    final picked = [
      for (final c in _completed)
        if (wanted.contains(c.id)) c,
    ];
    if (picked.isEmpty) return null;

    final replaceTail = _syntheticTail && _isBareNewline(visible);
    final starts = _lineStarts(visible);
    final end = documentLength(visible);
    final change = Delta();
    var cursor = 0;
    for (var i = 0; i < picked.length; i++) {
      final c = picked[i];
      final line = _unchecked(c.delta);
      if (replaceTail) {
        if (i < picked.length - 1) {
          _append(change, line);
        } else {
          // Reuse the placeholder newline as this line's newline.
          final ops = line.toList();
          for (final op in ops.take(ops.length - 1)) {
            change.insert(op.data, op.attributes);
          }
          change.retain(1, ops.last.attributes);
        }
        continue;
      }
      final at = _snap(starts, c.anchor, end);
      if (at > cursor) {
        change.retain(at - cursor);
        cursor = at;
      }
      _append(change, line);
    }
    if (replaceTail) _syntheticTail = false;

    // A remaining line moves down by the length of every restored line that
    // preceded it in document order.
    var shift = 0;
    final remaining = <CompletedLine>[];
    for (final c in _completed) {
      if (wanted.contains(c.id)) {
        shift += c.length;
      } else {
        c.anchor += shift;
        remaining.add(c);
      }
    }
    _completed
      ..clear()
      ..addAll(remaining);
    return change;
  }

  /// Drops completed lines for good. Returns them (in document order) so the
  /// caller can offer undo through [putBack].
  List<CompletedLine> remove(Iterable<int> ids) {
    final wanted = ids.toSet();
    final gone = <CompletedLine>[];
    int? prev;
    for (final c in _completed) {
      if (wanted.contains(c.id)) {
        c._prevId = prev;
        gone.add(c);
      }
      prev = c.id;
    }
    _completed.removeWhere((c) => wanted.contains(c.id));
    return gone;
  }

  /// Reverses [remove] (pass the lines it returned, in that order): each
  /// line goes back right after the line that preceded it, or, if that line
  /// is gone, at the place its anchor says.
  void putBack(List<CompletedLine> lines) {
    for (final l in lines) {
      var i = _completed.indexWhere((c) => c.id == l._prevId);
      if (i >= 0) {
        i++;
      } else if (l._prevId == null) {
        i = 0;
        while (i < _completed.length && _completed[i].anchor < l.anchor) {
          i++;
        }
      } else {
        i = _completed.length;
        while (i > 0 && _completed[i - 1].anchor > l.anchor) {
          i--;
        }
      }
      _completed.insert(i, l);
    }
  }

  // ---------------------------------------------------------------- helpers

  static void _append(Delta target, Delta ops) {
    for (final op in ops.toList()) {
      target.insert(op.data, op.attributes);
    }
  }

  /// [line] with its newline marked unchecked, as separate text and newline
  /// ops (the newline always last, alone).
  static Delta _unchecked(Delta line) {
    final ops = line.toList();
    final texts = <Operation>[];
    Map<String, dynamic> block = const {};
    for (final op in ops) {
      final d = op.data;
      if (d is String && d.endsWith('\n')) {
        if (d.length > 1) {
          texts.add(
            Operation.insert(d.substring(0, d.length - 1), op.attributes),
          );
        }
        block = {...?op.attributes};
      } else {
        texts.add(op);
      }
    }
    final strings = texts.where((o) => o.data is String).toList();
    final struckThrough =
        strings.isNotEmpty &&
        strings.every((o) => o.attributes?['strike'] == true);
    final out = Delta();
    for (final op in texts) {
      var attrs = op.attributes;
      if (struckThrough && attrs != null && attrs.containsKey('strike')) {
        attrs = Map.of(attrs)..remove('strike');
        if (attrs.isEmpty) attrs = null;
      }
      out.insert(op.data, attrs);
    }
    out.insert('\n', {...block, 'list': 'unchecked'});
    return out;
  }

  static bool _isBareNewline(Delta d) {
    final ops = d.toList();
    return ops.length == 1 &&
        ops.first.data == '\n' &&
        (ops.first.attributes == null || ops.first.attributes!.isEmpty);
  }

  /// Offsets at which a line starts, ascending; always begins with 0.
  static List<int> _lineStarts(Delta d) {
    final starts = <int>[0];
    var offset = 0;
    for (final op in d.toList()) {
      final data = op.data;
      if (data is String) {
        var from = 0;
        while (true) {
          final nl = data.indexOf('\n', from);
          if (nl < 0) break;
          starts.add(offset + nl + 1);
          from = nl + 1;
        }
      }
      offset += op.length ?? 0;
    }
    return starts;
  }

  /// The first line start at or after [anchor], or [end].
  static int _snap(List<int> starts, int anchor, int end) {
    if (anchor <= 0) return 0;
    if (anchor >= end) return end;
    var lo = 0;
    var hi = starts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (starts[mid] < anchor) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < starts.length ? starts[lo] : end;
  }

  static List<_Line> _linesOf(Delta d) {
    final lines = <_Line>[];
    var offset = 0;
    var lineStart = 0;
    for (final op in d.toList()) {
      final data = op.data;
      if (data is String) {
        var from = 0;
        while (true) {
          final nl = data.indexOf('\n', from);
          if (nl < 0) break;
          final end = offset + nl + 1;
          lines.add(_Line(lineStart, end, op.attributes ?? const {}));
          lineStart = end;
          from = nl + 1;
        }
      }
      offset += op.length ?? 0;
    }
    if (offset > lineStart) lines.add(_Line(lineStart, offset, const {}));
    return lines;
  }
}

class _Line {
  _Line(this.start, this.end, this.attributes);
  final int start;

  /// Exclusive; includes the newline.
  final int end;
  final Map<String, dynamic> attributes;
  int get length => end - start;
  bool get checked => attributes['list'] == 'checked';
}
