import 'dart:convert';

/// One line of a Quill document: its text and the block attributes carried by
/// the newline that ends it.
class DocLine {
  DocLine(this.text, this.attributes, {this.embeds = 0});

  final String text;
  final Map<String, dynamic> attributes;

  /// Number of embeds (images etc.) on the line.
  final int embeds;

  String? get list => attributes['list'] as String?;
  bool get isChecked => list == 'checked';
  bool get isUnchecked => list == 'unchecked';
  bool get isTask => isChecked || isUnchecked;
}

/// What the library needs to know about a note body without rendering it.
class DocDigest {
  DocDigest({
    required this.plainText,
    required this.preview,
    required this.tasksTotal,
    required this.tasksDone,
    required this.imageSources,
  });

  /// Full text, one document line per line. Indexed for search.
  final String plainText;

  /// Short card text. Completed tasks are left out; open tasks are marked.
  final String preview;

  final int tasksTotal;
  final int tasksDone;

  /// Sources of image embeds, in document order.
  final List<String> imageSources;

  bool get isBlank => plainText.trim().isEmpty && imageSources.isEmpty;
}

const emptyBodyJson = '[{"insert":"\\n"}]';

/// Parses a stored body into ops. Accepts a bare op array or `{"ops": [...]}`.
/// Throws [FormatException] for anything else.
List<Map<String, dynamic>> decodeOps(String bodyJson) {
  final raw = jsonDecode(bodyJson);
  final list = raw is Map ? raw['ops'] : raw;
  if (list is! List) throw const FormatException('Body is not a Delta');
  return [
    for (final op in list)
      if (op is Map)
        Map<String, dynamic>.from(op)
      else
        throw const FormatException('Delta op is not an object'),
  ];
}

/// Splits ops into lines. Only `insert` ops are meaningful in a document.
List<DocLine> linesOf(List<Map<String, dynamic>> ops, {List<String>? images}) {
  final lines = <DocLine>[];
  final text = StringBuffer();
  var embeds = 0;
  for (final op in ops) {
    final insert = op['insert'];
    final attrs = op['attributes'];
    if (insert is String) {
      var start = 0;
      while (true) {
        final nl = insert.indexOf('\n', start);
        if (nl < 0) {
          text.write(insert.substring(start));
          break;
        }
        text.write(insert.substring(start, nl));
        lines.add(
          DocLine(
            text.toString(),
            attrs is Map ? Map<String, dynamic>.from(attrs) : const {},
            embeds: embeds,
          ),
        );
        text.clear();
        embeds = 0;
        start = nl + 1;
      }
    } else if (insert is Map) {
      embeds++;
      final image = insert['image'];
      if (image is String) images?.add(image);
    }
  }
  if (text.isNotEmpty || embeds > 0) {
    lines.add(DocLine(text.toString(), const {}, embeds: embeds));
  }
  return lines;
}

/// Derives search text, card preview and task counts from a stored body.
DocDigest digestBody(
  String bodyJson, {
  int previewLines = 10,
  int previewChars = 360,
}) {
  final images = <String>[];
  final lines = linesOf(decodeOps(bodyJson), images: images);
  var total = 0;
  var done = 0;
  final plain = StringBuffer();
  final preview = <String>[];
  var previewLen = 0;
  var ordinal = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (i > 0) plain.write('\n');
    plain.write(line.text);
    if (line.isTask) {
      total++;
      if (line.isChecked) done++;
    }
    ordinal = line.list == 'ordered' ? ordinal + 1 : 0;
    if (line.isChecked) continue;
    final trimmed = line.text.trimRight();
    if (trimmed.trim().isEmpty) continue;
    if (preview.length >= previewLines || previewLen >= previewChars) continue;
    final marker = switch (line.list) {
      'unchecked' => '☐ ',
      'bullet' => '• ',
      'ordered' => '$ordinal. ',
      _ => '',
    };
    var entry = '$marker$trimmed';
    entry = _truncate(entry, previewChars - previewLen);
    preview.add(entry);
    previewLen += entry.length;
  }
  return DocDigest(
    plainText: plain.toString(),
    preview: preview.join('\n'),
    tasksTotal: total,
    tasksDone: done,
    imageSources: images,
  );
}

/// Cuts [s] to at most [max] UTF-16 units without splitting a surrogate pair.
String _truncate(String s, int max) {
  if (s.length <= max) return s;
  var end = max;
  final unit = s.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) end--;
  return '${s.substring(0, end).trimRight()}…';
}

/// A body holding [text] as plain paragraphs.
String bodyFromPlainText(String text) {
  final t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return jsonEncode([
    {'insert': t.endsWith('\n') ? t : '$t\n'},
  ]);
}
