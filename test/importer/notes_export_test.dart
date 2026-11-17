import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/importer/notes_export.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;
  setUp(() {
    db = AppDatabase.open(null);
    repo = NoteRepository(db);
  });
  tearDown(() => db.close());

  test('exports notes, tombstones, folders and attachments; parses back', () {
    final folder = repo.createFolder('Work');
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final att = repo.putAttachment(bytes, 'image/png');
    final a = repo.createNote(
      title: 'A',
      body: jsonEncode([
        {'insert': 'hello\n'},
        {
          'insert': {'image': att},
        },
        {'insert': '\n'},
      ]),
      folderId: folder.id,
    );
    final b = repo.createNote(title: 'B', body: bodyFromPlainText('gone'));
    repo.purge([b.id]);

    final text = exportAll(repo, now: DateTime.utc(2026, 1, 2, 3, 4, 5));
    final json = jsonDecode(text) as Map;
    expect(json['format'], 'notes-export');
    expect(json['version'], 1);
    expect(json['exportedAt'], '2026-01-02T03:04:05.000Z');
    expect(json['deviceId'], db.deviceId);

    final parsed = parseExport(text);
    expect(parsed.deviceId, db.deviceId);
    expect(parsed.notes.map((n) => n.id).toSet(), {a.id, b.id});
    expect(parsed.notes.firstWhere((n) => n.id == b.id).purged, isTrue);
    expect(parsed.notes.firstWhere((n) => n.id == a.id).title, 'A');
    expect(parsed.notes.firstWhere((n) => n.id == a.id).folderId, folder.id);
    expect(parsed.folders.single.name, 'Work');
    expect(parsed.attachments.single.hash, sha256Hex(bytes));
    expect(parsed.attachments.single.data, bytes);
    expect(parsed.attachments.single.mime, 'image/png');
    // Exact record round trip.
    final original = {for (final (_, r) in repo.noteRecordsSince(0)) r.id: r};
    for (final n in parsed.notes) {
      expect(n.toJson(), original[n.id]!.toJson());
    }
    // An attachment still waiting for its bytes is not exported.
    repo.createNote(
      body: jsonEncode([
        {
          'insert': {'image': 'att:${'f' * 64}'},
        },
        {'insert': '\n'},
      ]),
    );
    expect(parseExport(exportAll(repo)).attachments, hasLength(1));
  });

  test('parseExport rejects what it does not understand', () {
    void bad(String s) => expect(() => parseExport(s), throwsFormatException);
    bad('nope');
    bad('[]');
    bad('{"format":"other","version":1}');
    bad('{"format":"notes-export","version":2}');
    bad('{"format":"notes-export","version":"1"}');
    bad('{"format":"notes-export","version":1}');
    final text = exportAll(repo);
    final j = jsonDecode(text) as Map<String, Object?>;
    j['attachments'] = [
      {
        'hash': 'a' * 64,
        'mime': 'x',
        'size': 1,
        'data': base64Encode([9]),
      },
    ];
    bad(jsonEncode(j));
  });
}
