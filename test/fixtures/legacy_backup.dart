import 'dart:convert';

/// Generator for SYNTHETIC legacy Notebook backups. Nothing here comes from
/// anyone's real data: every title, text, date and id is invented from the
/// note's index.

const legacyDefaultColor = 0xFF252529;

/// Legacy backup shaped like the real one: 84 notes (42 active, 2 archived,
/// 40 deleted), 97 transactions, one embedded image.
Map<String, Object?> realisticPreset() => buildLegacyBackup(
  active: 42,
  archived: 2,
  deleted: 40,
  checklists: 12,
  rich: 8,
  images: 1,
  plainText: 3,
  transactions: 97,
  tombstones: 5,
);

/// One image path used by [buildLegacyBackup]'s image notes.
String imagePathFor(int n) => '/data/user/0/legacy.app/files/img_$n.jpg';

/// Builds a legacy export object.
///
/// Notes are numbered 0.. in order active, archived, deleted; their kinds
/// (checklist, rich, image, plain text, simple) are spread across the whole
/// range so every state holds a mix.
Map<String, Object?> buildLegacyBackup({
  int active = 6,
  int archived = 1,
  int deleted = 2,
  int checklists = 2,
  int rich = 2,
  int images = 1,
  int plainText = 1,
  List<String> folders = const ['Work', 'Ideas'],
  int tombstones = 2,
  int transactions = 3,
  int version = 11,
  int? colorEvery = 10,
  int? tagsEvery = 6,
  int? noteTagsEvery = 9,
  int? reminderEvery = 20,
  int? lockedEvery = 25,
  bool boolForms = true,
  String exportedAt = '2025-06-01T12:00:00.000',
}) {
  final total = active + archived + deleted;
  var stride = 1;
  for (final s in [13, 11, 7, 5, 3]) {
    if (_gcd(s, total == 0 ? 1 : total) == 1) {
      stride = s;
      break;
    }
  }
  final kinds = List<String>.filled(total, 'simple');
  final order = [
    for (var i = 0; i < checklists; i++) 'checklist',
    for (var i = 0; i < rich; i++) 'rich',
    for (var i = 0; i < images; i++) 'image',
    for (var i = 0; i < plainText; i++) 'plain',
  ];
  for (var k = 0; k < order.length && k < total; k++) {
    kinds[(k * stride) % total] = order[k];
  }
  final sentinels = <String?>['All Notes', 'Notes', '', null];
  final notes = <Map<String, Object?>>[];
  final tags = <Map<String, Object?>>[];
  final noteTags = <Map<String, Object?>>[];
  var imageNo = 0;
  for (var i = 0; i < total; i++) {
    final created = DateTime(2024, 1, 1, 8).add(Duration(hours: i * 7));
    final modified = created.add(const Duration(minutes: 90));
    final state = i < active
        ? 'active'
        : (i < active + archived ? 'archived' : 'deleted');
    final kind = kinds[i];
    String? imagePath;
    String content;
    switch (kind) {
      case 'checklist':
        content = _checklist(i);
      case 'rich':
        content = _rich(i);
      case 'image':
        imagePath = imagePathFor(imageNo++);
        content = jsonEncode([
          {'insert': 'Photo note $i\n'},
          {
            'insert': {'image': imagePath},
          },
          {'insert': '\n'},
        ]);
      case 'plain':
        content = i.isEven
            ? 'Plain text note $i\nsecond line'
            : '[not json at all $i';
      default:
        // Every fifth simple note lacks the final newline.
        content = jsonEncode([
          {'insert': 'Simple note $i body${i % 5 == 0 ? '' : '\n'}'},
        ]);
    }
    final category = folders.isNotEmpty && i % 3 == 0
        ? (i % 2 == 0
              ? folders[i % folders.length]
              : ' ${folders[i % folders.length].toLowerCase()} ')
        : sentinels[i % sentinels.length];
    bool? b(bool v) => v;
    Object flag(bool v) => boolForms && i.isOdd ? b(v)! : (v ? 1 : 0);
    notes.add({
      'id': 'legacy-note-${i.toString().padLeft(5, '0')}',
      'title': i % 11 == 0 ? '' : 'Title $i',
      'content': content,
      'dateCreated': created.toIso8601String(),
      'dateModified': modified.toIso8601String(),
      'color': colorEvery != null && i % colorEvery == 3
          ? 4294198070
          : legacyDefaultColor,
      'isPinned': flag(i % 8 == 0),
      'isArchived': flag(state == 'archived'),
      'imagePath': imagePath,
      'category': category,
      'tags': tagsEvery != null && i % tagsEvery == 1
          ? '["alpha","beta"]'
          : null,
      'previewText': 'preview $i',
      'deletedAt': state == 'deleted'
          ? modified.add(const Duration(days: 1)).toIso8601String()
          : null,
      'reminderAt': reminderEvery != null && i % reminderEvery == 4
          ? created.add(const Duration(days: 3)).toIso8601String()
          : null,
      'isLocked': flag(lockedEvery != null && i % lockedEvery == 7),
    });
    if (noteTagsEvery != null && i % noteTagsEvery == 2) {
      noteTags.add({
        'note_id': 'legacy-note-${i.toString().padLeft(5, '0')}',
        'tag_name': 'gamma',
      });
    }
  }
  if (noteTags.isNotEmpty || tagsEvery != null) {
    tags.addAll([
      {'name': 'alpha', 'color': 1},
      {'name': 'beta', 'color': 2},
      {'name': 'gamma', 'color': 3},
    ]);
  }
  return {
    'notes': notes,
    'tags': tags,
    'noteTags': noteTags,
    'transactions': [
      for (var i = 0; i < transactions; i++)
        {
          '_id': i + 1,
          'title': 'Synthetic payment $i',
          'amount': 10.0 + i,
          'isExpense': i.isEven ? 1 : 0,
          'category': 'Other',
          'date': DateTime(2024, 2, 1).add(Duration(days: i)).toIso8601String(),
        },
    ],
    'categoryDefinitions': <Object?>[],
    'periodLogs': [
      if (transactions > 0)
        {'id': 'p1', 'startDate': '2024-03-01T00:00:00.000'},
    ],
    'deletedNotes': [
      for (var i = 0; i < tombstones; i++)
        {
          'id': 'legacy-tombstone-$i',
          'deletedAt': DateTime(
            2024,
            5,
            1,
          ).add(Duration(days: i)).toIso8601String(),
        },
    ],
    'settings': {'textSize': 16.0, 'themeMode': 0},
    'version': version,
    'exportedAt': exportedAt,
  };
}

String encodeLegacyBackup(Map<String, Object?> backup) =>
    const JsonEncoder.withIndent('  ').convert(backup);

/// The ops a note's `content` carries, exactly as generated (for tests that
/// compare stored bodies with the source).
List<Object?> sourceOps(String content) {
  final d = jsonDecode(content);
  return d is Map ? d['ops'] as List<Object?> : d as List<Object?>;
}

String _checklist(int i) => jsonEncode([
  {'insert': 'Shopping $i'},
  {
    'insert': '\n',
    'attributes': {'header': 2},
  },
  {'insert': 'milk'},
  {
    'insert': '\n',
    'attributes': {'list': 'unchecked'},
  },
  {
    'insert': 'bread',
    'attributes': {'strike': true},
  },
  {
    'insert': '\n',
    'attributes': {'list': 'checked'},
  },
  {'insert': 'eggs'},
  {
    'insert': '\n',
    'attributes': {'list': 'checked'},
  },
  {'insert': 'tea'},
  {
    'insert': '\n',
    'attributes': {'list': 'unchecked'},
  },
]);

String _rich(int i) => jsonEncode({
  'ops': [
    {'insert': 'Rich $i'},
    {
      'insert': '\n',
      'attributes': {'header': 1},
    },
    {
      'insert': 'bold',
      'attributes': {'bold': true, 'color': '#ff0000'},
    },
    {'insert': ' and '},
    {
      'insert': 'italic',
      'attributes': {'italic': true, 'underline': true, 'x-unknown': 'keep'},
    },
    {'insert': ' and '},
    {
      'insert': 'link',
      'attributes': {'link': 'https://example.invalid/page'},
    },
    {'insert': '\n'},
    {'insert': 'first'},
    {
      'insert': '\n',
      'attributes': {'list': 'bullet'},
    },
    {'insert': 'nested'},
    {
      'insert': '\n',
      'attributes': {'list': 'bullet', 'indent': 1},
    },
    {'insert': 'step'},
    {
      'insert': '\n',
      'attributes': {'list': 'ordered'},
    },
    {'insert': 'quoted'},
    {
      'insert': '\n',
      'attributes': {'blockquote': true},
    },
    {'insert': 'code line'},
    {
      'insert': '\n',
      'attributes': {'code-block': true},
    },
    {
      'insert': {'table': '{"rows":[["a","b"]]}'},
    },
    {'insert': '\n'},
  ],
});

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
