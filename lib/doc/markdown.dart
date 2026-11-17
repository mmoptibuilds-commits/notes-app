import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import 'delta_text.dart';

/// Markdown conversion for note bodies (Quill Delta JSON).
///
/// Hand written on top of `package:markdown` rather than `markdown_quill`:
/// that package throws on embeds it does not know, asserts on a document
/// without a final newline, and escapes `.`, `-`, `!`, `#` everywhere
/// (`3.14` becomes `3\.14`).
///
/// Output form (one canonical form, so export -> import -> export is stable):
///  * blocks are separated by one blank line, list items by a single newline;
///  * `**bold**`, `*italic*`, `~~strike~~`, `` `code` ``, `[text](url)`;
///  * lists nest by four spaces; checklists are `- [ ]` / `- [x]`;
///  * empty paragraphs and surrounding whitespace of a line are not kept.
/// Underline, colour, size, alignment and other attributes have no Markdown
/// form and are dropped; their text is kept. An embed other than an image or
/// divider is written as its type in brackets.

const _blockKeys = {
  'header',
  'list',
  'blockquote',
  'code-block',
  'indent',
  'align',
  'direction',
};

class _Seg {
  _Seg.text(this.text, this.attrs) : embed = null;
  _Seg.embed(this.embed) : text = null, attrs = const {};
  final String? text;
  final Map<String, dynamic> attrs;
  final Map<String, dynamic>? embed;
}

class _QLine {
  _QLine(this.segs, this.block);
  final List<_Seg> segs;
  final Map<String, dynamic> block;
}

List<_QLine> _qlines(List<Map<String, dynamic>> ops) {
  final lines = <_QLine>[];
  var cur = <_Seg>[];
  for (final op in ops) {
    final insert = op['insert'];
    final rawAttrs = op['attributes'];
    final attrs = rawAttrs is Map
        ? Map<String, dynamic>.from(rawAttrs)
        : <String, dynamic>{};
    if (insert is String) {
      final inline = {
        for (final e in attrs.entries)
          if (!_blockKeys.contains(e.key)) e.key: e.value,
      };
      final block = {
        for (final e in attrs.entries)
          if (_blockKeys.contains(e.key)) e.key: e.value,
      };
      var start = 0;
      while (true) {
        final nl = insert.indexOf('\n', start);
        if (nl < 0) {
          if (start < insert.length) {
            cur.add(_Seg.text(insert.substring(start), inline));
          }
          break;
        }
        if (nl > start) cur.add(_Seg.text(insert.substring(start, nl), inline));
        lines.add(_QLine(cur, block));
        cur = [];
        start = nl + 1;
      }
    } else if (insert is Map) {
      cur.add(_Seg.embed(Map<String, dynamic>.from(insert)));
    }
  }
  if (cur.isNotEmpty) lines.add(_QLine(cur, {}));
  return lines;
}

final _escapeRe = RegExp(r'[\\`*_\[\]<~]');
String _esc(String s) => s.replaceAllMapped(_escapeRe, (m) => '\\${m[0]}');

String _encodeUrl(String u) => u
    .replaceAll(' ', '%20')
    .replaceAll('(', '%28')
    .replaceAll(')', '%29')
    .replaceAll('<', '%3C')
    .replaceAll('>', '%3E');

String _codeSpan(String s) {
  var longest = 0;
  for (final m in RegExp('`+').allMatches(s)) {
    if (m.group(0)!.length > longest) longest = m.group(0)!.length;
  }
  final fence = '`' * (longest + 1);
  final pad = s.startsWith('`') || s.endsWith('`') ? ' ' : '';
  return '$fence$pad$s$pad$fence';
}

final _wsLead = RegExp(r'^\s+');
final _wsTrail = RegExp(r'\s+$');

String _renderInline(List<_Seg> segs) {
  final out = StringBuffer();
  final stack = <String>[]; // open marks, outermost first
  String opener(String m) => m.startsWith('link:') ? '[' : m;

  void write(String s) => out.write(s);

  void close(String mark) {
    var s = out.toString();
    final trail = _wsTrail.firstMatch(s)?.group(0) ?? '';
    if (trail.isNotEmpty) s = s.substring(0, s.length - trail.length);
    out.clear();
    if (mark.startsWith('link:')) {
      out.write('$s](${mark.substring(5)})$trail');
    } else {
      out.write('$s$mark$trail');
    }
  }

  bool transition(Set<String> desired, String leadWs) {
    final reopen = <String>[];
    while (stack.isNotEmpty && !desired.containsAll(stack)) {
      final top = stack.removeLast();
      close(top);
      if (desired.contains(top)) reopen.add(top);
    }
    final toOpen = [
      for (final m in _markOrder(desired))
        if (!stack.contains(m)) m,
    ];
    if (toOpen.isNotEmpty) write(leadWs);
    for (final m in toOpen) {
      stack.add(m);
      write(opener(m));
    }
    return toOpen.isNotEmpty;
  }

  for (final seg in segs) {
    if (seg.embed != null) {
      transition(const {}, '');
      write(_embedText(seg.embed!));
      continue;
    }
    final text = seg.text!;
    final a = seg.attrs;
    final desired = <String>{
      if (a['link'] is String && (a['link'] as String).isNotEmpty)
        'link:${_encodeUrl(a['link'] as String)}',
      if (a['bold'] == true) '**',
      if (a['italic'] == true) '*',
      if (a['strike'] == true) '~~',
    };
    final lead = _wsLead.firstMatch(text)?.group(0) ?? '';
    final core = text.substring(lead.length);
    if (core.trim().isEmpty) {
      // Whitespace only: stays inside whatever is open.
      write(text);
      continue;
    }
    final trail = _wsTrail.firstMatch(core)?.group(0) ?? '';
    final body = core.substring(0, core.length - trail.length);
    if (!transition(desired, lead)) write(lead);
    write(a['code'] == true ? _codeSpan(body) : _esc(body));
    write(trail);
  }
  transition(const {}, '');
  return out.toString();
}

List<String> _markOrder(Set<String> marks) {
  final link = marks.where((m) => m.startsWith('link:')).toList();
  return [
    ...link,
    if (marks.contains('**')) '**',
    if (marks.contains('*')) '*',
    if (marks.contains('~~')) '~~',
  ];
}

String _embedText(Map<String, dynamic> embed) {
  final image = embed['image'];
  if (image is String) return '![](${_encodeUrl(image)})';
  if (embed.isEmpty) return '';
  final type = embed.keys.first;
  return _esc('[$type]');
}

final _lineStartRe = RegExp(
  r'^( *)(#{1,6}(?= |$)|>|[-+](?= |$)|-{3,}|\d{1,9}(?=[.)]( |$)))',
);

String _escapeLineStart(String s) {
  final m = _lineStartRe.firstMatch(s);
  if (m == null) return s;
  final pre = m.group(1)!;
  final tok = m.group(2)!;
  if (RegExp(r'^\d').hasMatch(tok)) {
    // Escape the dot or paren after the number.
    return '$pre$tok\\${s.substring(pre.length + tok.length)}';
  }
  return '$pre\\${s.substring(pre.length)}';
}

String _content(_QLine l) => _escapeLineStart(_renderInline(l.segs).trim());

bool _isDivider(_QLine l) =>
    l.segs.length == 1 &&
    l.segs.first.embed != null &&
    l.segs.first.embed!.containsKey('divider');

/// Converts a note body (Delta JSON) to Markdown. Never throws on unknown
/// embeds or attributes; throws [FormatException] only if [bodyJson] is not a
/// Delta at all.
String deltaToMarkdown(String bodyJson) {
  final lines = _qlines(decodeOps(bodyJson));
  final blocks = <String>[];
  final isList = <bool>[];
  final ordinals = <int, int>{};
  var i = 0;
  void add(String s, {bool list = false}) {
    blocks.add(s);
    isList.add(list);
  }

  while (i < lines.length) {
    final l = lines[i];
    final b = l.block;
    if (b['code-block'] != null && b['code-block'] != false) {
      final code = <String>[];
      final lang = b['code-block'] is String && b['code-block'] != 'plain'
          ? b['code-block'] as String
          : '';
      while (i < lines.length &&
          lines[i].block['code-block'] != null &&
          lines[i].block['code-block'] != false) {
        code.add(
          lines[i].segs
              .map(
                (s) => s.text ?? (s.embed != null ? _embedText(s.embed!) : ''),
              )
              .join(),
        );
        i++;
      }
      var longest = 2;
      for (final c in code) {
        for (final m in RegExp('`{3,}').allMatches(c)) {
          if (m.group(0)!.length > longest) longest = m.group(0)!.length;
        }
      }
      final fence = '`' * (longest + 1);
      add('$fence$lang\n${code.join('\n')}\n$fence');
      ordinals.clear();
      continue;
    }
    i++;
    if (_isDivider(l)) {
      add('---');
      ordinals.clear();
      continue;
    }
    final text = _content(l);
    final list = b['list'];
    if (list is String) {
      final level = (b['indent'] is int ? b['indent'] as int : 0).clamp(0, 20);
      // Reset numbering of deeper levels and of other kinds at this level.
      ordinals.removeWhere((k, _) => k > level);
      if (text.isEmpty) continue;
      final pad = '    ' * level;
      final String marker;
      switch (list) {
        case 'ordered':
          final n = (ordinals[level] ?? 0) + 1;
          ordinals[level] = n;
          marker = '$n. ';
        case 'checked':
          ordinals.remove(level);
          marker = '- [x] ';
        case 'unchecked':
          ordinals.remove(level);
          marker = '- [ ] ';
        default:
          ordinals.remove(level);
          marker = '- ';
      }
      add('$pad$marker$text', list: true);
      continue;
    }
    ordinals.clear();
    if (text.isEmpty) continue;
    final header = b['header'];
    if (header is int && header >= 1) {
      add('${'#' * header.clamp(1, 6)} ${_renderInline(l.segs).trim()}');
    } else if (b['blockquote'] == true) {
      add('> $text');
    } else {
      add(text);
    }
  }
  if (blocks.isEmpty) return '';
  final out = StringBuffer(blocks.first);
  for (var k = 1; k < blocks.length; k++) {
    final tight = isList[k] && isList[k - 1];
    final quotes = blocks[k].startsWith('> ') && blocks[k - 1].startsWith('> ');
    out.write(tight || quotes ? '\n' : '\n\n');
    out.write(blocks[k]);
  }
  out.write('\n');
  return out.toString();
}

// ------------------------------------------------------------------ import

class _Break {
  const _Break();
}

const _br = _Break();

/// Converts Markdown to a note body (Delta JSON, always ending in a newline).
String markdownToDelta(String markdown) {
  final doc = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  final nodes = doc.parseLines(
    markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'),
  );
  final lines = <_OutLine>[];
  for (final n in nodes) {
    _block(n, lines, quoted: false);
  }
  if (lines.isEmpty) return emptyBodyJson;
  final ops = <Map<String, dynamic>>[];
  for (final l in lines) {
    for (final op in l.ops) {
      final prev = ops.isEmpty ? null : ops.last;
      if (prev != null &&
          prev['insert'] is String &&
          op['insert'] is String &&
          !(prev['insert'] as String).endsWith('\n') &&
          jsonEncode(prev['attributes']) == jsonEncode(op['attributes'])) {
        prev['insert'] = '${prev['insert']}${op['insert']}';
      } else {
        ops.add(Map<String, dynamic>.of(op));
      }
    }
    ops.add({'insert': '\n', if (l.block.isNotEmpty) 'attributes': l.block});
  }
  return jsonEncode(ops);
}

class _OutLine {
  _OutLine(this.ops, this.block);
  final List<Map<String, dynamic>> ops;
  final Map<String, dynamic> block;
}

Map<String, dynamic> _sortedAttrs(Map<String, dynamic> a) => {
  for (final k in (a.keys.toList()..sort())) k: a[k],
};

void _inline(md.Node n, Map<String, dynamic> attrs, List<Object> out) {
  if (n is md.Text) {
    final parts = n.text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) out.add(_br);
      if (parts[i].isNotEmpty) {
        out.add({
          'insert': parts[i],
          if (attrs.isNotEmpty) 'attributes': _sortedAttrs(attrs),
        });
      }
    }
    return;
  }
  final e = n as md.Element;
  switch (e.tag) {
    case 'br':
      out.add(_br);
    case 'img':
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) {
        out.add({
          'insert': {'image': src},
        });
      }
    case 'input':
      break;
    case 'code':
      for (final c in e.children ?? const <md.Node>[]) {
        _inline(c, {...attrs, 'code': true}, out);
      }
    default:
      final next = {...attrs};
      switch (e.tag) {
        case 'strong':
          next['bold'] = true;
        case 'em':
          next['italic'] = true;
        case 'del':
          next['strike'] = true;
        case 'a':
          final href = e.attributes['href'];
          if (href != null && href.isNotEmpty) next['link'] = href;
      }
      for (final c in e.children ?? const <md.Node>[]) {
        _inline(c, next, out);
      }
  }
}

/// Splits inline pieces into lines. Empty lines are kept only if [keepEmpty].
List<_OutLine> _split(
  List<Object> pieces,
  Map<String, dynamic> block, {
  bool keepEmpty = false,
}) {
  final out = <_OutLine>[];
  var cur = <Map<String, dynamic>>[];
  void finish() {
    if (cur.isNotEmpty || keepEmpty) out.add(_OutLine(cur, {...block}));
    cur = [];
  }

  for (final p in pieces) {
    if (p is _Break) {
      finish();
    } else {
      cur.add(p as Map<String, dynamic>);
    }
  }
  finish();
  return out;
}

const _inlineTags = {
  'strong',
  'em',
  'del',
  'code',
  'a',
  'img',
  'br',
  'input',
  'span',
};

void _block(md.Node n, List<_OutLine> lines, {required bool quoted}) {
  final q = quoted
      ? <String, dynamic>{'blockquote': true}
      : <String, dynamic>{};
  if (n is md.Text) {
    final pieces = <Object>[];
    _inline(n, {}, pieces);
    lines.addAll(_split(pieces, q));
    return;
  }
  final e = n as md.Element;
  final tag = e.tag;
  final children = e.children ?? const <md.Node>[];
  if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
    final pieces = <Object>[];
    for (final c in children) {
      _inline(c, {}, pieces);
    }
    lines.addAll(_split(pieces, {'header': int.parse(tag.substring(1))}));
  } else if (tag == 'p' || _inlineTags.contains(tag)) {
    final pieces = <Object>[];
    _inline(e, {}, pieces);
    lines.addAll(_split(pieces, q));
  } else if (tag == 'blockquote') {
    for (final c in children) {
      _block(c, lines, quoted: true);
    }
  } else if (tag == 'ul' || tag == 'ol') {
    _list(e, lines, 0);
  } else if (tag == 'pre') {
    var code = e.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    String? lang;
    final first = children.isNotEmpty ? children.first : null;
    if (first is md.Element) {
      final cls = first.attributes['class'];
      if (cls != null && cls.startsWith('language-')) {
        lang = cls.substring('language-'.length);
      }
    }
    for (final line in code.split('\n')) {
      lines.add(
        _OutLine(
          [
            if (line.isNotEmpty) {'insert': line},
          ],
          {'code-block': lang ?? true},
        ),
      );
    }
  } else if (tag == 'hr') {
    lines.add(
      _OutLine([
        {
          'insert': {'divider': 'hr'},
        },
      ], {}),
    );
  } else if (tag == 'table') {
    void rows(md.Element el) {
      for (final c in el.children ?? const <md.Node>[]) {
        if (c is! md.Element) continue;
        if (c.tag == 'tr') {
          final cells = [
            for (final cell in c.children ?? const <md.Node>[])
              cell.textContent.trim(),
          ];
          lines.add(
            _OutLine([
              {'insert': cells.join(' | ')},
            ], {}),
          );
        } else {
          rows(c);
        }
      }
    }

    rows(e);
  } else {
    // Unknown block: keep its text.
    final pieces = <Object>[];
    for (final c in children) {
      _inline(c, {}, pieces);
    }
    lines.addAll(_split(pieces, q));
  }
}

void _list(md.Element list, List<_OutLine> lines, int indent) {
  final ordered = list.tag == 'ol';
  for (final li in list.children ?? const <md.Node>[]) {
    if (li is! md.Element || li.tag != 'li') continue;
    var kind = ordered ? 'ordered' : 'bullet';
    final children = li.children ?? const <md.Node>[];
    for (final c in children) {
      if (c is md.Element && c.tag == 'input') {
        kind = c.attributes.containsKey('checked') ? 'checked' : 'unchecked';
      }
    }
    final attrs = <String, dynamic>{
      'list': kind,
      if (indent > 0) 'indent': indent,
    };
    var emitted = false;
    var pieces = <Object>[];
    void flush() {
      for (final l in _split(pieces, attrs)) {
        lines.add(l);
        emitted = true;
      }
      pieces = [];
    }

    for (final c in children) {
      if (c is md.Element && (c.tag == 'ul' || c.tag == 'ol')) {
        flush();
        if (!emitted) {
          lines.add(_OutLine([], {...attrs}));
          emitted = true;
        }
        _list(c, lines, indent + 1);
      } else if (c is md.Element && c.tag == 'p') {
        flush();
        for (final cc in c.children ?? const <md.Node>[]) {
          _inline(cc, {}, pieces);
        }
        flush();
      } else if (c is md.Text ||
          (c is md.Element && _inlineTags.contains(c.tag))) {
        _inline(c, {}, pieces);
      } else {
        flush();
        _block(c, lines, quoted: false);
        emitted = true;
      }
    }
    flush();
    if (!emitted) lines.add(_OutLine([], {...attrs}));
  }
}
