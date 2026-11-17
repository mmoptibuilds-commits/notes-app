import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/version_vector.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/delta_text.dart';

String body(String text) => jsonEncode([
  {'insert': '$text\n'},
]);

void main() {
  late AppDatabase db;
  late NoteRepository repo;
  var now = 1000000;

  setUp(() {
    now = 1000000;
    db = AppDatabase.open(null, wallClock: () => now);
    repo = NoteRepository(db, nowMs: () => now);
  });
  tearDown(() => db.close());

  test('create, read back, list', () {
    final n = repo.createNote(title: 'Hello', body: body('world'));
    final got = repo.getNote(n.id)!;
    expect(got.title, 'Hello');
    expect(got.body, body('world'));
    expect(got.preview, 'world');
    expect(got.contentVv, VersionVector({db.deviceId: 1}));
    expect(repo.listNotes().single.id, n.id);
    expect(repo.getNote('missing'), isNull);
  });

  test('saveContent: saves, reports unchanged, advances the version', () {
    final n = repo.createNote(body: body('a'));
    now += 5000;
    final r1 = repo.saveContent(
      n.id,
      title: 'T',
      body: body('b'),
      base: n.contentVv,
    );
    expect(r1.outcome, SaveOutcome.saved);
    expect(r1.contentVv.compare(n.contentVv), VvOrder.dominates);
    final seq = db.currentSeq;
    final r2 = repo.saveContent(
      n.id,
      title: 'T',
      body: body('b'),
      base: r1.contentVv,
    );
    expect(r2.outcome, SaveOutcome.unchanged);
    expect(db.currentSeq, seq, reason: 'an unchanged save must not write');
    final got = repo.getNote(n.id)!;
    expect(got.updatedAt.millisecondsSinceEpoch, 1005000);
    expect(got.createdAt.millisecondsSinceEpoch, 1000000);
  });

  test('saveContent rejects a malformed body and leaves the note alone', () {
    final n = repo.createNote(body: body('good'));
    expect(
      () =>
          repo.saveContent(n.id, title: '', body: 'garbage', base: n.contentVv),
      throwsFormatException,
    );
    expect(repo.getNote(n.id)!.body, body('good'));
  });

  test(
    'saveContent on a stale base keeps the other version as a conflict copy',
    () {
      final n = repo.createNote(title: 'Plan', body: body('original'));
      // Sync writes a newer version underneath the open editor.
      final remote = repo.getRecord(n.id)!;
      db.transaction(
        () => repo.writeRecord(
          remote.copyWith(
            body: body('from the other device'),
            contentVv: remote.contentVv.increment('otherdevice'),
          ),
        ),
      );
      final r = repo.saveContent(
        n.id,
        title: 'Plan',
        body: body('typed here'),
        base: n.contentVv,
      );
      expect(r.outcome, SaveOutcome.savedWithConflictCopy);
      expect(repo.getNote(n.id)!.body, body('typed here'));
      final copy = repo.getNote(r.conflictCopyId!)!;
      expect(copy.body, body('from the other device'));
      expect(copy.conflictOf, n.id);
      expect(
        r.contentVv['otherdevice'],
        1,
        reason: 'the saved version must supersede the remote one',
      );
      expect(repo.counts().conflicts, 1);
      expect(repo.listNotes(scope: NoteScope.conflicts).single.id, copy.id);
      repo.keepConflictCopy([copy.id]);
      expect(repo.counts().conflicts, 0);
      expect(repo.getNote(copy.id), isNotNull);
    },
  );

  test('conflict copy is deterministic and never recreated once it exists', () {
    final n = repo.createNote(body: body('x'));
    final rec = repo.getRecord(n.id)!;
    final a = NoteRepository.conflictCopyOf(rec);
    final b = NoteRepository.conflictCopyOf(rec);
    expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()));
    final id = db.transaction(() => repo.insertConflictCopyIfAbsent(rec));
    repo.purge([id]);
    db.transaction(() => repo.insertConflictCopyIfAbsent(rec));
    expect(repo.getNote(id), isNull, reason: 'a deleted copy stays deleted');
  });

  test('pin, archive, trash, restore, purge and the scopes they land in', () {
    final a = repo.createNote(title: 'a');
    now += 10;
    final b = repo.createNote(title: 'b');
    now += 10;
    final c = repo.createNote(title: 'c');
    expect(repo.listNotes().map((n) => n.title), ['c', 'b', 'a']);
    repo.setPinned([a.id], true);
    expect(repo.listNotes().map((n) => n.title), ['a', 'c', 'b']);
    repo.setArchived([b.id], true);
    expect(repo.listNotes().map((n) => n.title), ['a', 'c']);
    expect(repo.listNotes(scope: NoteScope.archived).single.title, 'b');
    now += 10;
    repo.trash([c.id, b.id]);
    expect(repo.listNotes(scope: NoteScope.trash).length, 2);
    expect(repo.listNotes(scope: NoteScope.archived), isEmpty);
    var k = repo.counts();
    expect([k.active, k.archived, k.trash], [1, 0, 2]);
    repo.restore([b.id]);
    expect(
      repo.listNotes(scope: NoteScope.archived).single.title,
      'b',
      reason: 'restore returns it to where it was',
    );
    repo.purge([c.id]);
    expect(repo.getNote(c.id), isNull);
    final tomb = repo.getRecord(c.id)!;
    expect(tomb.purged, isTrue);
    expect(tomb.title, '');
    expect(tomb.body, emptyBodyJson);
    expect(tomb.contentVv[db.deviceId], 2);
    k = repo.counts();
    expect([k.active, k.archived, k.trash], [1, 1, 0]);
    // Metadata changes never touch the content version.
    expect(repo.getRecord(a.id)!.contentVv, a.contentVv);
  });

  test('emptyTrash purges only trashed notes', () {
    final a = repo.createNote(title: 'keep');
    final b = repo.createNote(title: 'bin');
    now += 1;
    repo.trash([b.id]);
    expect(repo.emptyTrash(), 1);
    expect(repo.getNote(a.id), isNotNull);
    expect(repo.getRecord(b.id)!.purged, isTrue);
    expect(repo.emptyTrash(), 0);
  });

  test('editing after trashing brings the note back', () {
    final n = repo.createNote(body: body('x'));
    now += 1;
    repo.trash([n.id]);
    expect(repo.getNote(n.id)!.isTrashed, isTrue);
    now += 1;
    repo.saveContent(n.id, title: '', body: body('y'), base: n.contentVv);
    expect(repo.getNote(n.id)!.isTrashed, isFalse);
  });

  test(
    'saving into a deleted-forever note revives it without a conflict copy',
    () {
      final n = repo.createNote(body: body('x'));
      repo.purge([n.id]);
      final r = repo.saveContent(
        n.id,
        title: '',
        body: body('still typing'),
        base: n.contentVv,
      );
      expect(r.outcome, SaveOutcome.saved);
      expect(repo.getNote(n.id)!.body, body('still typing'));
    },
  );

  test(
    'folders: create, dedupe by name, rename, counts, delete unfiles notes',
    () {
      final work = repo.createFolder(' Work ');
      expect(work.name, 'Work');
      expect(repo.createFolder('work').id, work.id);
      final home = repo.createFolder('Home');
      final a = repo.createNote(title: 'a', folderId: work.id);
      final b = repo.createNote(title: 'b');
      repo.moveToFolder([b.id], work.id);
      repo.createNote(title: 'c');
      expect(repo.listFolders().map((f) => '${f.name}:${f.noteCount}'), [
        'Home:0',
        'Work:2',
      ]);
      expect(repo.listNotes(folder: FolderFilter.folder(work.id)).length, 2);
      expect(
        repo.listNotes(folder: const FolderFilter.unfiled()).single.title,
        'c',
      );
      expect(repo.counts().unfiled, 1);
      repo.renameFolder(home.id, 'House');
      expect(repo.listFolders().first.name, 'House');
      repo.deleteFolder(work.id);
      expect(repo.listFolders().map((f) => f.name), ['House']);
      expect(repo.getNote(a.id)!.folderId, isNull);
      expect(repo.listNotes(folder: const FolderFilter.unfiled()).length, 3);
      expect(() => repo.createFolder('  '), throwsArgumentError);
    },
  );

  test('search: all words, prefix on the last, title ranked first, scopes', () {
    repo.createNote(title: 'Groceries', body: body('buy oat milk and bread'));
    repo.createNote(
      title: 'Trip',
      body: body('pack the milkshake recipe and groceries list'),
    );
    final binned = repo.createNote(title: 'Old groceries', body: body('x'));
    now += 1;
    repo.trash([binned.id]);
    final hits = repo.search('groc');
    expect(hits.map((h) => h.note.title), ['Groceries', 'Trip']);
    expect(repo.search('milk bread').single.note.title, 'Groceries');
    expect(repo.search('mil').length, 2);
    expect(
      repo.search('bread').single.snippet,
      contains('${SearchHit.matchStart}bread${SearchHit.matchEnd}'),
    );
    expect(
      repo.search('groceries', scope: NoteScope.trash).single.note.id,
      binned.id,
    );
    expect(repo.search('   '), isEmpty);
    expect(repo.search('"'), isEmpty);
    // FTS syntax in user input is literal text, never an error.
    for (final q in [
      'AND OR NOT',
      'milk AND',
      'a:b',
      '(milk',
      'mi*lk',
      "o'neil",
      '-milk',
      'NEAR(a b)',
    ]) {
      expect(() => repo.search(q), returnsNormally, reason: q);
    }
  });

  test('search index follows edits and deletions', () {
    final n = repo.createNote(body: body('alpha'));
    expect(repo.search('alpha').length, 1);
    repo.saveContent(n.id, title: '', body: body('beta'), base: n.contentVv);
    expect(repo.search('alpha'), isEmpty);
    expect(repo.search('beta').length, 1);
    repo.purge([n.id]);
    expect(repo.search('beta'), isEmpty);
    expect(
      db.select(
        "INSERT INTO notes_fts(notes_fts) VALUES ('integrity-check') RETURNING 1",
      ),
      isA<Object>(),
    );
  });

  test('accents and case are ignored when searching', () {
    repo.createNote(body: body('Café Zürich'));
    expect(repo.search('cafe zurich').length, 1);
  });

  test(
    'attachments: stored by hash, tracked per note, collected when unused',
    () {
      final bytes = Uint8List.fromList(List.generate(2000, (i) => i % 251));
      final src = repo.putAttachment(bytes, 'image/png');
      expect(src, startsWith('att:'));
      expect(repo.putAttachment(bytes, 'image/png'), src);
      expect(repo.getAttachment(src), bytes);
      final withImage = jsonEncode([
        {
          'insert': {'image': src},
        },
        {'insert': '\n'},
        {
          'insert': {'image': 'att:${'f' * 64}'},
        },
        {'insert': '\n'},
      ]);
      final n = repo.createNote(body: withImage);
      expect(repo.missingAttachments(), ['f' * 64]);
      expect(repo.collectUnusedAttachments(), 0);
      repo.purge([n.id]);
      expect(repo.collectUnusedAttachments(), 2);
      expect(repo.getAttachment(src), isNull);
    },
  );

  test('every change is queued with a rising sequence number', () {
    final a = repo.createNote(title: 'a');
    final b = repo.createNote(title: 'b');
    final mark = db.currentSeq;
    repo.setPinned([a.id], true);
    final f = repo.createFolder('F');
    final pending = repo.noteRecordsSince(mark);
    expect(pending.single.$2.id, a.id);
    expect(repo.folderRecordsSince(mark).single.$2.id, f.id);
    expect(repo.noteRecordsSince(0).map((e) => e.$2.id).toSet(), {a.id, b.id});
    final r = pending.single.$2;
    expect(
      jsonEncode(
        NoteRecord.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>,
        ).toJson(),
      ),
      jsonEncode(r.toJson()),
    );
  });

  test('listeners hear once per committed change and not for reads', () {
    var heard = 0;
    repo.changes.addListener(() => heard++);
    final n = repo.createNote(title: 'a');
    expect(heard, 1);
    repo.listNotes();
    repo.search('a');
    repo.getNote(n.id);
    expect(heard, 1);
    repo.setPinned([n.id, 'missing'], true);
    expect(heard, 2);
  });

  test('sorting', () {
    repo.createNote(title: 'banana');
    now += 10;
    repo.createNote(title: 'Apple');
    now += 10;
    final c = repo.createNote(title: '', body: body('cherry'));
    now += 10;
    repo.saveContent(
      repo.listNotes(sort: NoteSort.title).first.id,
      title: 'Apple',
      body: body('edited'),
      base: VersionVector.empty,
    );
    expect(
      repo
          .listNotes(sort: NoteSort.title)
          .where((n) => !n.isConflictCopy)
          .map((n) => n.title.isEmpty ? n.preview : n.title),
      ['Apple', 'banana', 'cherry'],
    );
    expect(
      repo
          .listNotes(sort: NoteSort.created)
          .where((n) => !n.isConflictCopy)
          .first
          .id,
      c.id,
    );
  });
}
