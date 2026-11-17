import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/core/version_vector.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/importer/legacy_backup.dart';

import '../fixtures/legacy_backup.dart';

/// Body the importer must store for a legacy `content` string.
String expectedBody(String content) {
  Object? d;
  try {
    d = jsonDecode(content);
  } on FormatException {
    return bodyFromPlainText(content);
  }
  final list = d is Map ? d['ops'] : d;
  if (list is! List) return bodyFromPlainText(content);
  final ops = [...list];
  final last = ops.isEmpty ? null : (ops.last as Map)['insert'];
  if (last is! String || !last.endsWith('\n')) ops.add({'insert': '\n'});
  return jsonEncode(ops);
}

bool truthy(Object? v) => v == true || v == 1;

/// Everything in the tables an import can touch, as comparable text.
String dumpDb(AppDatabase db) {
  final b = StringBuffer('seq=${db.currentSeq}\n');
  for (final t in [
    'notes',
    'folders',
    'attachments',
    'note_attachments',
    'import_batches',
    'import_records',
    'local_meta',
  ]) {
    b.writeln('## $t');
    for (final r in db.select('SELECT * FROM $t ORDER BY 1, 2')) {
      b.writeln(r.values.join('|'));
    }
  }
  return b.toString();
}

void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late LegacyBackupImporter importer;
  var now = 1800000000000;

  void open() {
    db = AppDatabase.open(null, wallClock: () => now);
    repo = NoteRepository(db, nowMs: () => now);
    importer = LegacyBackupImporter(repo, nowMs: () => now);
  }

  setUp(() {
    now = 1800000000000;
    open();
  });
  tearDown(() => db.close());

  String enc(Map<String, Object?> m) => jsonEncode(m);
  List<Map<String, Object?>> rowsOf(Map<String, Object?> m) =>
      (m['notes'] as List).cast<Map<String, Object?>>();

  test('imports the preset: counts, bodies, titles, flags, timestamps', () {
    final backup = realisticPreset();
    final report = importer.import(enc(backup), sourceName: 'backup.json');

    final c = repo.counts();
    expect((c.active, c.archived, c.trash), (42, 2, 40));
    expect(c.conflicts, 0);
    expect(report.sourceNotes, 84);
    expect(report.bySourceState, {'active': 42, 'archived': 2, 'deleted': 40});
    expect(report.actions['created'], 84);
    expect(report.plainTextConverted, 3);
    expect(report.tombstones, 5);
    expect(report.outOfScopeTables['transactions'], 97);
    expect(report.outOfScopeTables['periodLogs'], 1);
    expect(report.missingImages, 1);
    expect(report.missingImageNoteIds, hasLength(1));
    expect(report.invalidRows, isEmpty);
    expect(repo.listNotes(scope: NoteScope.active), hasLength(42));

    final noteTags = (backup['noteTags'] as List).cast<Map>();
    final tagged = {for (final t in noteTags) t['note_id']};
    int carried(bool Function(Map<String, Object?>) f) =>
        rowsOf(backup).where(f).length;
    expect(report.unsupportedFields, {
      'color': carried((r) => r['color'] != legacyDefaultColor),
      'tags': carried((r) => r['tags'] != null || tagged.contains(r['id'])),
      'reminderAt': carried((r) => r['reminderAt'] != null),
      'isLocked': carried((r) => truthy(r['isLocked'])),
      'imagePath': carried((r) => r['imagePath'] != null),
      'previewText': 84,
    });

    final folderNames = {for (final f in repo.listFolders()) f.id: f.name};
    expect(folderNames.values.map((n) => n.toLowerCase()).toSet(), {
      'work',
      'ideas',
    });
    expect(report.foldersCreated, 2);

    for (final row in rowsOf(backup)) {
      final rec = repo.getRecord(row['id'] as String)!;
      expect(rec.body, expectedBody(row['content'] as String));
      expect(rec.title, row['title']);
      final created = DateTime.parse(row['dateCreated'] as String);
      final modified = DateTime.parse(row['dateModified'] as String);
      expect(rec.createdAt, created.millisecondsSinceEpoch);
      expect(rec.updatedAt, modified.millisecondsSinceEpoch);
      expect(rec.pinned, truthy(row['isPinned']));
      expect(rec.archived, truthy(row['isArchived']));
      final deleted = row['deletedAt'] != null;
      expect(rec.trashedAt != null, deleted);
      if (deleted) {
        expect(
          rec.trashedAt,
          DateTime.parse(row['deletedAt'] as String).millisecondsSinceEpoch,
        );
      }
      final cat = (row['category'] as String?)?.trim() ?? '';
      if (cat.isEmpty || cat == 'All Notes' || cat == 'Notes') {
        expect(rec.folderId, isNull);
      } else {
        expect(folderNames[rec.folderId]?.toLowerCase(), cat.toLowerCase());
      }
      expect(rec.purged, isFalse);
      expect(rec.conflictOf, isNull);
      expect(rec.contentHlc.node, 'legacy');
      expect(rec.contentHlc.millis, rec.updatedAt);
      expect(rec.contentVv.counters.keys.single, startsWith('legacy:'));
    }
    // Untouched content keeps unknown attributes and embeds exactly.
    final rich = rowsOf(backup)
        .firstWhere((r) => (r['content'] as String).contains('x-unknown'));
    final stored = repo.getRecord(rich['id'] as String)!.body;
    expect(stored, contains('"x-unknown":"keep"'));
    expect(stored, contains('"table"'));
    final check = rowsOf(backup)
        .firstWhere((r) => (r['content'] as String).contains('"strike":true'));
    expect(
      repo.getRecord(check['id'] as String)!.body,
      expectedBody(check['content'] as String),
    );
  });

  test('summary and stored report carry no note text', () {
    final backup = realisticPreset();
    final report = importer.import(enc(backup));
    final text = report.summary() + jsonEncode(report.toJson());
    expect(text, isNot(contains('Title 1')));
    expect(text, isNot(contains('img_0.jpg')));
    final info = importer.batches().single;
    expect(info.report!.sourceNotes, 84);
    expect(info.report!.actions['created'], 84);
    expect(info.isRolledBack, isFalse);
    expect(info.formatVersion, 11);
  });

  test('re-import adds and changes nothing', () {
    final text = enc(realisticPreset());
    importer.import(text);
    final before = dumpDb(db).split('## import_batches').first;
    final seq = db.currentSeq;
    final again = importer.import(text);
    expect(db.currentSeq, seq);
    expect(again.actions['unchanged'], 84);
    expect(again.actions['created'], 0);
    expect(dumpDb(db).split('## import_batches').first, before);
    expect(repo.counts().active, 42);
    expect(importer.batches(), hasLength(2));
  });

  test('two separate databases get identical rows', () {
    final text = enc(realisticPreset());
    importer.import(text);
    final db2 = AppDatabase.open(null, wallClock: () => now + 999999);
    addTearDown(db2.close);
    final repo2 = NoteRepository(db2, nowMs: () => now + 999999);
    LegacyBackupImporter(repo2, nowMs: () => 5).import(text);
    List<String> notes(NoteRepository r) =>
        ([for (final (_, n) in r.noteRecordsSince(0)) n]
              ..sort((a, b) => a.id.compareTo(b.id)))
            .map((n) => jsonEncode(n.toJson()))
            .toList();
    List<String> folders(NoteRepository r) =>
        ([for (final (_, f) in r.folderRecordsSince(0)) f]
              ..sort((a, b) => a.id.compareTo(b.id)))
            .map((f) => jsonEncode(f.toJson()))
            .toList();
    expect(notes(repo2), notes(repo));
    expect(folders(repo2), folders(repo));
    expect(notes(repo), hasLength(84));
  });

  test('inspect writes nothing', () {
    final text = enc(realisticPreset());
    final before = dumpDb(db);
    final report = importer.inspect(text, sourceName: 'x.json');
    expect(dumpDb(db), before);
    expect(report.dryRun, isTrue);
    expect(report.actions['created'], 84);
    expect(report.foldersCreated, 2);
    expect(importer.batches(), isEmpty);
    expect(repo.counts().active, 0);
  });

  test('a locally edited note is left alone by a re-import', () {
    final text = enc(buildLegacyBackup());
    importer.import(text);
    final id = 'legacy-note-00001';
    final n = repo.getNote(id)!;
    repo.saveContent(
      id,
      title: 'mine',
      body: bodyFromPlainText('my edit'),
      base: n.contentVv,
    );
    final seq = db.currentSeq;
    final again = importer.import(text);
    expect(again.actions['unchanged'], 9);
    expect(db.currentSeq, seq);
    expect(repo.getNote(id)!.title, 'mine');
  });

  test('a newer backup updates an untouched note, keeping metadata', () {
    final v1 = buildLegacyBackup();
    importer.import(enc(v1));
    final id = 'legacy-note-00000';
    repo.setPinned([id], true);
    final pinnedHlc = repo.getRecord(id)!.pinnedHlc;
    final before = repo.getRecord(id)!;

    final v2 = jsonDecode(enc(v1)) as Map<String, Object?>;
    final row = rowsOf(v2).first;
    row['content'] = jsonEncode([
      {'insert': 'Rewritten in the newer backup\n'},
    ]);
    row['dateModified'] = '2026-01-01T00:00:00.000';
    row['isPinned'] = 0;
    final report = importer.import(enc(v2));
    expect(report.actions['updated'], 1);
    expect(report.actions['unchanged'], 8);
    final after = repo.getRecord(id)!;
    expect(after.body, contains('Rewritten'));
    expect(after.pinned, isTrue, reason: 'metadata registers are kept');
    expect(after.pinnedHlc, pinnedHlc);
    expect(
      after.updatedAt,
      DateTime.parse('2026-01-01T00:00:00.000').millisecondsSinceEpoch,
    );
    expect(after.contentVv.compare(before.contentVv), VvOrder.dominates);

    // Importing the same v2 again changes nothing; an older one is a no-op.
    final seq = db.currentSeq;
    expect(importer.import(enc(v2)).actions['unchanged'], 9);
    expect(importer.import(enc(v1)).actions['unchanged'], 9);
    expect(db.currentSeq, seq);
  });

  test('a different version of an edited note becomes a conflict copy', () {
    final v1 = buildLegacyBackup();
    importer.import(enc(v1));
    final id = 'legacy-note-00001';
    final n = repo.getNote(id)!;
    repo.saveContent(
      id,
      title: 'local title',
      body: bodyFromPlainText('local text'),
      base: n.contentVv,
    );
    final v2 = jsonDecode(enc(v1)) as Map<String, Object?>;
    final row = rowsOf(v2)[1];
    row['content'] = jsonEncode([
      {'insert': 'Source text of the newer backup\n'},
    ]);
    row['dateModified'] = '2026-02-02T00:00:00.000';

    final report = importer.import(enc(v2));
    expect(report.actions['conflict_copy'], 1);
    expect(repo.getNote(id)!.title, 'local title');
    expect(repo.getNote(id)!.body, bodyFromPlainText('local text'));
    final copies = repo.listNotes(scope: NoteScope.conflicts);
    expect(copies, hasLength(1));
    expect(copies.single.conflictOf, id);
    expect(
      repo.getNote(copies.single.id)!.body,
      expectedBody(row['content'] as String),
    );

    final seq = db.currentSeq;
    final again = importer.import(enc(v2));
    expect(again.actions['conflict_copy'], 0);
    expect(db.currentSeq, seq);
    expect(repo.listNotes(scope: NoteScope.conflicts), hasLength(1));

    // Rolling back the batch removes the untouched copy, not the local note.
    final batch = importer.batches().last; // oldest = v1 import
    expect(batch.report!.actions['created'], 9);
    final conflictBatch = importer.batches()[1];
    final rb = importer.rollback(conflictBatch.id);
    expect(rb.copiesPurged, 1);
    expect(repo.listNotes(scope: NoteScope.conflicts), isEmpty);
    expect(repo.getNote(id)!.title, 'local title');
  });

  test('a note deleted forever is not resurrected', () {
    final text = enc(buildLegacyBackup());
    importer.import(text);
    repo.purge(['legacy-note-00002']);
    final report = importer.import(text);
    expect(report.actions['skipped_deleted'], 1);
    expect(repo.getNote('legacy-note-00002'), isNull);
    expect(repo.getRecord('legacy-note-00002')!.purged, isTrue);
  });

  test('rollback removes untouched notes, keeps edited, is idempotent', () {
    final text = enc(realisticPreset());
    final report = importer.import(text);
    final editId = 'legacy-note-00001';
    final n = repo.getNote(editId)!;
    repo.saveContent(
      editId,
      title: 'kept',
      body: bodyFromPlainText('edited after import'),
      base: n.contentVv,
    );
    final editedFolder = repo.getRecord(editId)!.folderId;

    final rb = importer.rollback(report.batchId);
    expect(rb.purged, 83);
    expect(rb.keptEdited, 1);
    expect(rb.alreadyRolledBack, isFalse);
    final c = repo.counts();
    expect(c.active + c.archived + c.trash, 1);
    expect(repo.getNote(editId)!.title, 'kept');
    // Folders created by the batch survive only while they hold a note.
    final left = repo.listFolders().map((f) => f.id).toSet();
    expect(left, editedFolder == null ? isEmpty : {editedFolder});
    expect(rb.foldersDeleted, 2 - left.length);
    expect(importer.batches().single.isRolledBack, isTrue);

    final seq = db.currentSeq;
    final again = importer.rollback(report.batchId);
    expect(again.alreadyRolledBack, isTrue);
    expect(db.currentSeq, seq);

    // Re-importing after the rollback restores what was removed.
    final re = importer.import(text);
    expect(re.actions['restored'], 83);
    expect(re.actions['unchanged'], 1);
    final c2 = repo.counts();
    expect((c2.active, c2.archived, c2.trash), (42, 2, 40));
    expect(repo.getNote(editId)!.title, 'kept');
    expect(repo.listFolders().map((f) => f.name.toLowerCase()).toSet(), {
      'work',
      'ideas',
    });
    for (final row in rowsOf(realisticPreset())) {
      if (row['id'] == editId) continue;
      expect(
        repo.getRecord(row['id'] as String)!.body,
        expectedBody(row['content'] as String),
      );
    }
  });

  test('rollback of an update puts the earlier content back', () {
    final v1 = buildLegacyBackup();
    importer.import(enc(v1));
    final id = 'legacy-note-00007'; // deleted note: stays in Trash
    final old = repo.getRecord(id)!;
    final v2 = jsonDecode(enc(v1)) as Map<String, Object?>;
    final row = rowsOf(v2)[7];
    row['content'] = jsonEncode([
      {'insert': 'newer text\n'},
    ]);
    row['dateModified'] = '2027-05-05T00:00:00.000';
    final report = importer.import(enc(v2));
    expect(report.actions['updated'], 1);
    expect(repo.getRecord(id)!.trashedAt, isNotNull);
    final rb = importer.rollback(report.batchId);
    expect(rb.reverted, 1);
    final back = repo.getRecord(id)!;
    expect(back.body, old.body);
    expect(back.title, old.title);
    expect(back.updatedAt, old.updatedAt);
    expect(back.trashedAt, isNotNull, reason: 'still in Trash');
  });

  test('a throwing onRecord leaves the database exactly as before', () {
    repo.createNote(title: 'local', body: bodyFromPlainText('mine'));
    repo.createFolder('Existing');
    final text = enc(realisticPreset());
    final before = dumpDb(db);
    expect(
      () => importer.import(
        text,
        onRecord: (i) {
          if (i == 40) throw StateError('boom');
        },
      ),
      throwsStateError,
    );
    expect(dumpDb(db), before);
    expect(importer.batches(), isEmpty);
    // And a clean run afterwards works.
    expect(importer.import(text).actions['created'], 84);
  });

  group('malformed input', () {
    void rejects(String text, Matcher message) {
      final before = dumpDb(db);
      expect(
        () => importer.import(text),
        throwsA(
          isA<LegacyBackupFormatException>().having(
            (e) => e.message,
            'message',
            message,
          ),
        ),
      );
      expect(
        () => importer.inspect(text),
        throwsA(isA<LegacyBackupFormatException>()),
      );
      expect(dumpDb(db), before);
    }

    test('not JSON', () => rejects('this is not json', contains('JSON')));
    test('a JSON array', () => rejects('[1,2]', contains('object')));
    test(
      'encrypted container',
      () => rejects(
        jsonEncode({
          'version': 2,
          'encrypted': true,
          'salt': 'AAAA',
          'iv': 'BBBB',
          'ciphertext': 'CCCC',
        }),
        contains('unencrypted'),
      ),
    );
    test(
      'encrypted container without the flag',
      () => rejects(
        jsonEncode({'salt': 'a', 'iv': 'b', 'ciphertext': 'c'}),
        contains('encrypted'),
      ),
    );
    test(
      'notes is not a list',
      () =>
          rejects(jsonEncode({'notes': 'x', 'version': 11}), contains('notes')),
    );
    test(
      'no notes key',
      () => rejects('{"transactions": []}', contains('notes')),
    );
  });

  test('rows with problems are reported, the rest imported', () {
    final backup = buildLegacyBackup(
      active: 3,
      archived: 0,
      deleted: 0,
      checklists: 0,
      rich: 0,
      images: 0,
      plainText: 0,
    );
    final rows = rowsOf(backup);
    backup['notes'] = <Object?>[
      ...rows,
      {'title': 'no id', 'content': 'x'},
      {'id': '', 'title': 'empty id'},
      'not a map',
      {...rows.first, 'title': 'duplicate'},
    ];
    final report = importer.import(enc(backup));
    expect(report.actions['created'], 3);
    expect(report.invalidRows.map((r) => r.index), [3, 4, 5, 6]);
    expect(report.invalidRows.map((r) => r.reason), [
      'missing or unusable id',
      'missing or unusable id',
      'row is not an object',
      'duplicate id',
    ]);
    expect(jsonEncode(report.toJson()), isNot(contains('no id')));
    expect(repo.counts().active, 3);
    expect(repo.getRecord('legacy-note-00000')!.title, isNot('duplicate'));
  });

  test('garbage content, flag forms and unparseable dates', () {
    final backup = <String, Object?>{
      'version': 11,
      'exportedAt': '2025-06-01T12:00:00.000Z',
      'notes': [
        {
          'id': 'a',
          'title': 'plain',
          'content': '[oops {{ not json',
          'dateCreated': '2024-01-01T10:00:00.000',
          'dateModified': '2024-01-02T10:00:00.000Z',
          'isPinned': true,
          'isArchived': 'false',
          'isLocked': false,
          'color': legacyDefaultColor,
        },
        {
          'id': 'b',
          'title': 'ops object, no trailing newline',
          'content': '{"ops":[{"insert":"abc","attributes":{"bold":true}}]}',
          'dateCreated': 'garbage',
          'dateModified': null,
          'isPinned': 1,
          'isArchived': 1,
          'deletedAt': 'also garbage',
        },
        {
          'id': 'c',
          'title': 'array of non-ops',
          'content': '[1, 2, 3]',
          'dateCreated': '2024-01-01',
          'dateModified': '2024-01-01',
        },
        {'id': 'd', 'title': 'no content', 'dateCreated': '2024-01-01'},
        {
          'id': 'e',
          'title': 'retain op is not a document',
          'content': '[{"retain": 3}]',
          'dateCreated': '2024-01-01',
          'dateModified': '2024-01-01',
        },
      ],
    };
    final report = importer.import(enc(backup));
    expect(report.plainTextConverted, 3);
    expect(report.warnings.any((w) => w.contains('timestamp')), isTrue);
    final a = repo.getRecord('a')!;
    expect(a.body, bodyFromPlainText('[oops {{ not json'));
    expect(a.pinned, isTrue);
    expect(a.archived, isFalse);
    expect(a.updatedAt, DateTime.utc(2024, 1, 2, 10).millisecondsSinceEpoch);
    final exported = DateTime.utc(2025, 6, 1, 12).millisecondsSinceEpoch;
    final b = repo.getRecord('b')!;
    expect(
      b.body,
      '[{"insert":"abc","attributes":{"bold":true}},{"insert":"\\n"}]',
    );
    expect(b.createdAt, exported);
    expect(b.pinned && b.archived, isTrue);
    expect(b.trashedAt, isNotNull, reason: 'a set but unreadable deletedAt');
    expect(repo.getRecord('c')!.body, bodyFromPlainText('[1, 2, 3]'));
    expect(repo.getRecord('d')!.body, emptyBodyJson);
    expect(repo.getRecord('e')!.body, bodyFromPlainText('[{"retain": 3}]'));
    expect(report.unsupportedFields['color'], 0);
  });

  test('versions: newer warns, missing warns, known is quiet', () {
    final base = buildLegacyBackup(active: 1, archived: 0, deleted: 0);
    expect(importer.inspect(enc(base)).warnings, isEmpty);
    final newer = {...base, 'version': 99};
    final r = importer.inspect(enc(newer));
    expect(r.formatVersion, 99);
    expect(r.warnings.single, contains('99'));
    final none = {...base}..remove('version');
    expect(importer.inspect(enc(none)).warnings.single, contains('version'));
    // A newer version is still imported.
    expect(importer.import(enc(newer)).actions['created'], 1);
  });

  test('folders: sentinels, trimming, reuse of existing folders', () {
    final existing = repo.createFolder('work'); // random id, same name
    final backup = <String, Object?>{
      'version': 11,
      'notes': [
        for (final (i, cat) in <String?>[
          null,
          '',
          'All Notes',
          'Notes',
          ' Work ',
          'WORK',
          'Travel ',
          'travel',
        ].indexed)
          {
            'id': 'f$i',
            'title': 't',
            'content': '',
            'dateCreated': '2024-01-01T00:00:00',
            'dateModified': '2024-01-01T00:00:00',
            'category': cat,
          },
      ],
    };
    final report = importer.import(enc(backup));
    String? folderOf(String id) => repo.getRecord(id)!.folderId;
    for (var i = 0; i < 4; i++) {
      expect(folderOf('f$i'), isNull);
    }
    expect(folderOf('f4'), existing.id);
    expect(folderOf('f5'), existing.id);
    final travel = folderOf('f6');
    expect(travel, derivedId('legacy-folder', ['travel']));
    expect(folderOf('f7'), travel);
    expect(report.foldersCreated, 1);
    final byId = {for (final f in repo.listFolders()) f.id: f};
    expect(byId[travel]!.name, 'Travel');
    final rec = repo.getFolderRecord(travel!)!;
    expect(rec.createdAt, 0);
    expect(
      (rec.nameHlc.millis, rec.nameHlc.counter, rec.nameHlc.node),
      (0, 1, 'legacy'),
    );
  });

  test(
    'images: missing ones are reported, attachImages stores and rewrites',
    () {
      final backup = realisticPreset();
      final report = importer.import(enc(backup));
      expect(report.missingImages, 1);
      final noteId = report.missingImageNoteIds.single;
      final path = imagePathFor(0);
      expect(repo.getRecord(noteId)!.body, contains(path));

      final bytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
      expect(importer.attachImages({'/somewhere/else.png': bytes}), 0);
      expect(importer.attachImages({path: bytes}), 1);
      final body = repo.getRecord(noteId)!.body;
      expect(body, isNot(contains(path)));
      final src = digestBody(body).imageSources.single;
      expect(src, '$attachmentScheme${sha256Hex(bytes)}');
      expect(repo.getAttachment(src), bytes);
      expect(
        db.select('SELECT mime FROM attachments').single['mime'],
        'image/png',
      );
      expect(importer.attachImages({path: bytes}), 0);
      // The embed was the only thing that changed: text is intact.
      expect(body, contains('Photo note'));
      // Re-importing the backup does not undo the user's attachment.
      final again = importer.import(enc(backup));
      expect(again.actions['unchanged'], 84);
      expect(repo.getRecord(noteId)!.body, body);
    },
  );

  test('imported text is searchable, in the right scope', () {
    importer.import(enc(realisticPreset()));
    final all = repo.search('Simple note');
    expect(all, isNotEmpty);
    expect(all.every((h) => h.note.trashedAt == null), isTrue);
    final deleted = repo.search('Simple note', scope: NoteScope.trash);
    expect(deleted, isNotEmpty);
    expect(repo.search('milk', scope: NoteScope.active), isNotEmpty);
    expect(repo.search('zzzznotthere'), isEmpty);
  });

  test('snapshotPath: written for a database on disk, skipped in memory', () {
    final dir = Directory.systemTemp.createTempSync('import_snap_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final text = enc(buildLegacyBackup());
    importer.import(text, snapshotPath: '${dir.path}/mem.bak');
    expect(File('${dir.path}/mem.bak').existsSync(), isFalse);

    final disk = AppDatabase.open('${dir.path}/notes.db');
    addTearDown(disk.close);
    final r = NoteRepository(disk);
    LegacyBackupImporter(r).import(text, snapshotPath: '${dir.path}/pre.bak');
    expect(File('${dir.path}/pre.bak').existsSync(), isTrue);
  });

  test('batches are listed newest first; unknown batch id is rejected', () {
    final a = importer.import(enc(buildLegacyBackup()), sourceName: 'one.json');
    now += 1000;
    final b = importer.import(
      enc(buildLegacyBackup(active: 2)),
      sourceName: 'two.json',
    );
    expect(importer.batches().map((x) => x.id), [b.batchId, a.batchId]);
    expect(importer.batches().first.sourceName, 'two.json');
    expect(() => importer.rollback('nope'), throwsArgumentError);
  });
}
