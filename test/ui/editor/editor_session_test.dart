import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/version_vector.dart';
import 'package:notes/data/editor_draft.dart';
import 'package:notes/data/editor_save_barrier.dart';
import 'package:notes/data/models.dart' show NoteScope;
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/checklist_projection.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_session.dart';

class _SerializationFailureSession extends EditorSession {
  _SerializationFailureSession({
    required super.repo,
    required super.saveBarrier,
    super.noteId,
    super.recoveredDraft,
    super.retryDelay,
  });

  bool failSerialization = false;

  @override
  Delta canonicalDelta() {
    if (failSerialization) throw StateError('injected serialization failure');
    return super.canonicalDelta();
  }
}

class _CountingNoteRepository extends NoteRepository {
  _CountingNoteRepository(super.db);

  int contentWriteAttempts = 0;

  @override
  EditorDraftWriteResult writeEditorContent({
    required String draftId,
    required String? noteId,
    required String title,
    required String body,
    required VersionVector base,
    bool requirePendingDraft = false,
    bool recoveringDraft = false,
    String? folderId,
  }) {
    contentWriteAttempts++;
    return super.writeEditorContent(
      draftId: draftId,
      noteId: noteId,
      title: title,
      body: body,
      base: base,
      requirePendingDraft: requirePendingDraft,
      recoveringDraft: recoveringDraft,
      folderId: folderId,
    );
  }
}

class _TransientRecoveryFailureRepository extends NoteRepository {
  _TransientRecoveryFailureRepository(super.db);

  bool failContentWrites = true;
  bool failDraftWrites = true;

  @override
  EditorDraftWriteResult writeEditorContent({
    required String draftId,
    required String? noteId,
    required String title,
    required String body,
    required VersionVector base,
    bool requirePendingDraft = false,
    bool recoveringDraft = false,
    String? folderId,
  }) {
    if (failContentWrites) throw StateError('injected content failure');
    return super.writeEditorContent(
      draftId: draftId,
      noteId: noteId,
      title: title,
      body: body,
      base: base,
      requirePendingDraft: requirePendingDraft,
      recoveringDraft: recoveringDraft,
      folderId: folderId,
    );
  }

  @override
  void savePendingEditorDraft(PendingEditorDraft draft) {
    if (failDraftWrites) throw StateError('injected draft failure');
    super.savePendingEditorDraft(draft);
  }

  @override
  bool savePendingEditorDraftFromHandoff(
    PendingEditorDraft draft, {
    required bool requireExisting,
  }) {
    if (failDraftWrites) throw StateError('injected draft failure');
    return super.savePendingEditorDraftFromHandoff(
      draft,
      requireExisting: requireExisting,
    );
  }
}

class _RetryAfterManyFailuresRepository extends NoteRepository {
  _RetryAfterManyFailuresRepository(super.db);

  int handoffAttempts = 0;

  @override
  EditorDraftWriteResult writeEditorContent({
    required String draftId,
    required String? noteId,
    required String title,
    required String body,
    required VersionVector base,
    bool requirePendingDraft = false,
    bool recoveringDraft = false,
    String? folderId,
  }) => throw StateError('synthetic storage failure');

  @override
  bool savePendingEditorDraftFromHandoff(
    PendingEditorDraft draft, {
    required bool requireExisting,
  }) {
    handoffAttempts++;
    if (handoffAttempts <= 2000) {
      throw StateError('synthetic storage failure');
    }
    return super.savePendingEditorDraftFromHandoff(
      draft,
      requireExisting: requireExisting,
    );
  }
}

class _FailOnceDraftLookupRepository extends NoteRepository {
  _FailOnceDraftLookupRepository(super.db);

  var failNextLookup = true;

  @override
  PendingEditorDraft? pendingEditorDraft(String id) {
    if (failNextLookup) {
      failNextLookup = false;
      throw StateError('synthetic transient read failure');
    }
    return super.pendingEditorDraft(id);
  }
}

String json(Delta d) => jsonEncode(d.toJson());

Delta shopping() => Delta()
  ..insert('Shopping')
  ..insert('\n', {'header': 1})
  ..insert('milk')
  ..insert('\n', {'list': 'unchecked'})
  ..insert('eggs', {'strike': true, 'bold': true})
  ..insert('\n', {'list': 'checked'})
  ..insert('bread')
  ..insert('\n', {'list': 'checked', 'indent': 1})
  ..insert('tea')
  ..insert('\n', {'list': 'unchecked'});

void main() {
  late AppServices s;
  late NoteRepository repo;
  setUp(() {
    s = AppServices.inMemory();
    repo = s.notes;
  });
  tearDown(() => s.close());

  EditorSession open(
    String? id, {
    bool completed = true,
    void Function(String)? onConflict,
  }) => EditorSession(
    repo: repo,
    noteId: id,
    useCompletedSection: completed,
    autosaveDelay: const Duration(hours: 1),
    onConflictCopy: onConflict,
  );

  String storedBody(String id) => repo.getNote(id)!.body;

  test('opening, idling and closing a note write nothing', () {
    final note = repo.createNote(title: 'T', body: json(shopping()));
    final seq = s.db.currentSeq;
    final e = open(note.id);
    expect(e.completed.map((c) => c.text), ['eggs', 'bread']);
    expect(json(e.quill.document.toDelta()), isNot(contains('eggs')));
    e.flush();
    e.dispose();
    expect(s.db.currentSeq, seq);
    expect(storedBody(note.id), json(shopping()));
  });

  test('editing another line keeps completed lines byte-for-byte', () {
    final note = repo.createNote(title: 'T', body: json(shopping()));
    final e = open(note.id);
    e.quill.replaceText(0, 0, 'My ', const TextSelection.collapsed(offset: 3));
    e.flush();
    final saved = deltaFromBody(storedBody(note.id));
    final expected = Delta()
      ..insert('My Shopping')
      ..insert('\n', {'header': 1})
      ..insert('milk')
      ..insert('\n', {'list': 'unchecked'})
      ..insert('eggs', {'strike': true, 'bold': true})
      ..insert('\n', {'list': 'checked'})
      ..insert('bread')
      ..insert('\n', {'list': 'checked', 'indent': 1})
      ..insert('tea')
      ..insert('\n', {'list': 'unchecked'});
    expect(json(saved), json(expected));
    e.dispose();
  });

  test(
    'checking an item moves it to the completed section and saves it in place',
    () async {
      final note = repo.createNote(body: json(shopping()));
      final e = open(note.id);
      var notified = 0;
      e.addListener(() => notified++);
      // "milk" starts at offset 9 ("Shopping\n"); its newline is at 13.
      e.quill.formatText(13, 0, Attribute.checked);
      await pumpEventQueue();
      expect(e.completed.map((c) => c.text), ['milk', 'eggs', 'bread']);
      expect(e.quill.document.toPlainText(), 'Shopping\ntea\n');
      expect(notified, greaterThan(0));
      e.flush();
      final saved = deltaFromBody(storedBody(note.id));
      final expected = Delta()
        ..insert('Shopping')
        ..insert('\n', {'header': 1})
        ..insert('milk')
        ..insert('\n', {'list': 'checked'})
        ..insert('eggs', {'strike': true, 'bold': true})
        ..insert('\n', {'list': 'checked'})
        ..insert('bread')
        ..insert('\n', {'list': 'checked', 'indent': 1})
        ..insert('tea')
        ..insert('\n', {'list': 'unchecked'});
      expect(json(saved), json(expected));
      // Reopening gives the same split.
      e.dispose();
      final again = open(note.id);
      expect(again.completed.map((c) => c.text), ['milk', 'eggs', 'bread']);
      again.dispose();
    },
  );

  test(
    'checking every item leaves an empty line and a saved, intact note',
    () async {
      final note = repo.createNote(
        body: json(
          Delta()
            ..insert('a')
            ..insert('\n', {'list': 'unchecked'})
            ..insert('b')
            ..insert('\n', {'list': 'unchecked'}),
        ),
      );
      final e = open(note.id);
      e.quill.formatText(1, 0, Attribute.checked);
      await pumpEventQueue();
      await pumpEventQueue();
      e.quill.formatText(1, 0, Attribute.checked);
      await pumpEventQueue();
      await pumpEventQueue();
      expect(e.completed.map((c) => c.text), ['a', 'b']);
      e.flush();
      expect(
        json(deltaFromBody(storedBody(note.id))),
        json(
          Delta()
            ..insert('a')
            ..insert('\n', {'list': 'checked'})
            ..insert('b')
            ..insert('\n', {'list': 'checked'}),
        ),
      );
      e.dispose();
    },
  );

  test('restoring puts items back unchecked in their place; legacy strike is removed', () {
    final note = repo.createNote(body: json(shopping()));
    final e = open(note.id);
    e.restoreCompleted([e.completed.first.id]); // eggs
    expect(e.quill.document.toPlainText(), 'Shopping\nmilk\neggs\ntea\n');
    e.uncheckAllCompleted();
    expect(e.completed, isEmpty);
    e.flush();
    final expected = Delta()
      ..insert('Shopping')
      ..insert('\n', {'header': 1})
      ..insert('milk')
      ..insert('\n', {'list': 'unchecked'})
      ..insert('eggs', {'bold': true})
      ..insert('\n', {'list': 'unchecked'})
      ..insert('bread')
      ..insert('\n', {'list': 'unchecked', 'indent': 1})
      ..insert('tea')
      ..insert('\n', {'list': 'unchecked'});
    expect(json(deltaFromBody(storedBody(note.id))), json(expected));
    e.dispose();
  });

  test('deleting completed items persists, and undo brings them back', () {
    final note = repo.createNote(body: json(shopping()));
    final e = open(note.id);
    final gone = e.deleteCompleted([e.completed.first.id]);
    expect(gone.single.text, 'eggs');
    e.flush();
    expect(storedBody(note.id), isNot(contains('eggs')));
    e.undoDelete(gone);
    e.flush();
    expect(json(deltaFromBody(storedBody(note.id))), json(shopping()));
    e.dispose();
  });

  test(
    'with the completed section off, checked lines stay in the document',
    () async {
      final note = repo.createNote(body: json(shopping()));
      final e = open(note.id, completed: false);
      expect(e.completed, isEmpty);
      expect(e.quill.document.toPlainText(), contains('eggs'));
      e.quill.formatText(13, 0, Attribute.checked);
      await pumpEventQueue();
      expect(e.quill.document.toPlainText(), contains('milk'));
      e.dispose();
    },
  );

  test(
    'a new note is created only when it has content, in the chosen folder',
    () {
      final folder = repo.createFolder('Work');
      final e = EditorSession(
        repo: repo,
        folderId: folder.id,
        autosaveDelay: const Duration(hours: 1),
      );
      e.flush();
      expect(repo.counts().active, 0);
      e.quill.replaceText(
        0,
        0,
        '   ',
        const TextSelection.collapsed(offset: 3),
      );
      e.flush();
      expect(repo.counts().active, 0, reason: 'whitespace is not content');
      e.quill.replaceText(
        0,
        0,
        'hello',
        const TextSelection.collapsed(offset: 5),
      );
      e.flush();
      final n = repo.listNotes().single;
      expect(e.noteId, n.id);
      expect(n.folderId, folder.id);
      // Further edits update the same note.
      e.title.text = 'Greeting';
      e.flush();
      expect(repo.listNotes().single.title, 'Greeting');
      expect(repo.listNotes().length, 1);
      e.dispose();
    },
  );

  test('a title alone is enough to keep a new note', () {
    final e = open(null)..title.text = 'Just a title';
    e.flush();
    expect(repo.listNotes().single.title, 'Just a title');
    e.dispose();
  });

  test('autosave fires after the delay and coalesces rapid edits', () {
    fakeAsync((fake) {
      final e = EditorSession(
        repo: repo,
        autosaveDelay: const Duration(milliseconds: 700),
      );
      e.quill.replaceText(0, 0, 'a', const TextSelection.collapsed(offset: 1));
      fake.elapse(const Duration(milliseconds: 500));
      e.quill.replaceText(1, 0, 'b', const TextSelection.collapsed(offset: 2));
      fake.elapse(const Duration(milliseconds: 500));
      expect(repo.listNotes(), isEmpty, reason: 'timer restarts on each edit');
      expect(e.status, SaveStatus.pending);
      fake.elapse(const Duration(milliseconds: 300));
      expect(repo.listNotes().single.preview, 'ab');
      expect(e.status, SaveStatus.idle);
      e.dispose();
    });
  });

  test('closing the editor flushes unsaved text', () {
    final e = open(null);
    e.quill.replaceText(0, 0, 'x', const TextSelection.collapsed(offset: 1));
    e.dispose();
    expect(repo.listNotes().single.preview, 'x');
  });

  test('a failed save keeps the text, reports it, and retries', () {
    fakeAsync((fake) {
      final note = repo.createNote(body: json(Delta()..insert('old\n')));
      final e = EditorSession(
        repo: repo,
        noteId: note.id,
        autosaveDelay: const Duration(milliseconds: 100),
        retryDelay: const Duration(seconds: 3),
      );
      e.quill.replaceText(
        0,
        0,
        'new ',
        const TextSelection.collapsed(offset: 4),
      );
      s.db.execute('ALTER TABLE notes RENAME TO notes_away');
      fake.elapse(const Duration(milliseconds: 150));
      expect(e.status, SaveStatus.failed);
      expect(e.lastError, isNotNull);
      expect(e.quill.document.toPlainText(), 'new old\n');
      s.db.execute('ALTER TABLE notes_away RENAME TO notes');
      fake.elapse(const Duration(seconds: 4));
      expect(e.status, SaveStatus.idle);
      expect(repo.getNote(note.id)!.preview, 'new old');
      e.dispose();
    });
  });

  test(
    'sync landing while editing becomes a conflict copy, nothing is lost',
    () {
      final note = repo.createNote(
        title: 'Plan',
        body: json(Delta()..insert('base\n')),
      );
      String? copy;
      final e = open(note.id, onConflict: (id) => copy = id);
      final remote = repo.getRecord(note.id)!;
      s.db.transaction(
        () => repo.writeRecord(
          remote.copyWith(
            body: json(Delta()..insert('from phone\n')),
            contentVv: remote.contentVv.increment('phone'),
          ),
        ),
      );
      e.quill.replaceText(
        0,
        0,
        'typed ',
        const TextSelection.collapsed(offset: 6),
      );
      e.flush();
      expect(copy, isNotNull);
      expect(repo.getNote(copy!)!.preview, 'from phone');
      expect(repo.getNote(note.id)!.preview, 'typed base');
      expect(e.quill.document.toPlainText(), 'typed base\n');
      // Later saves are plain saves again.
      e.quill.replaceText(0, 0, '!', const TextSelection.collapsed(offset: 1));
      e.flush();
      expect(repo.listNotes(scope: NoteScope.conflicts).length, 1);
      e.dispose();
    },
  );

  test('a note in Trash is read-only and untouched until restored', () {
    final note = repo.createNote(body: json(Delta()..insert('keep\n')));
    repo.trash([note.id]);
    final seq = s.db.currentSeq;
    final e = open(note.id);
    expect(e.readOnly, isTrue);
    expect(e.quill.readOnly, isTrue);
    e.title.text = 'changed';
    e.flush();
    e.dispose();
    expect(s.db.currentSeq, seq);
    final again = open(note.id);
    again.restoreFromTrash();
    expect(again.readOnly, isFalse);
    expect(repo.getNote(note.id)!.isTrashed, isFalse);
    again.dispose();
  });

  test('an unreadable body is shown read-only and never overwritten', () {
    final note = repo.createNote(body: json(Delta()..insert('ok\n')));
    s.db.execute("UPDATE notes SET body = 'not a delta' WHERE id = ?", [
      note.id,
    ]);
    final seq = s.db.currentSeq;
    final e = open(note.id);
    expect(e.loadError, isNotNull);
    expect(e.readOnly, isTrue);
    e.title.text = 'x';
    e.flush();
    e.dispose();
    expect(s.db.currentSeq, seq);
    expect(s.db.select('SELECT body FROM notes').single['body'], 'not a delta');
  });

  test('a missing note opens read-only with a message', () {
    final e = open('nope');
    expect(e.loadError, isNotNull);
    expect(e.readOnly, isTrue);
    e.dispose();
  });

  test('plain text for copying includes title and completed items', () {
    final note = repo.createNote(title: 'List', body: json(shopping()));
    final e = open(note.id);
    expect(e.plainText(), 'List\n\nShopping\nmilk\neggs\nbread\ntea');
    e.dispose();
  });

  test('note operations store a pending new note first', () {
    final e = open(null);
    e.quill.replaceText(
      0,
      0,
      'pin me',
      const TextSelection.collapsed(offset: 6),
    );
    e.setPinned(true);
    expect(repo.listNotes().single.pinned, isTrue);
    e.trash();
    expect(repo.counts().trash, 1);
    e.dispose();
  });

  test(
    'text typed just before a failing save is not lost when the editor closes',
    () {
      fakeAsync((fake) {
        final note = repo.createNote(body: json(Delta()..insert('old\n')));
        final e = EditorSession(
          repo: repo,
          noteId: note.id,
          autosaveDelay: const Duration(milliseconds: 100),
          retryDelay: const Duration(seconds: 3),
        );
        e.quill.replaceText(
          0,
          0,
          'precious ',
          const TextSelection.collapsed(offset: 9),
        );
        s.db.execute('ALTER TABLE notes RENAME TO notes_away');
        e.dispose(); // the editor closes while storage is failing
        fake.elapse(const Duration(seconds: 7));
        final draft = repo.pendingEditorDrafts().single;
        expect(draft.body, contains('precious old'));
        s.db.execute('ALTER TABLE notes_away RENAME TO notes');
        expect(repo.getNote(note.id)!.preview, 'old');
        final recovered = EditorSession(repo: repo, recoveredDraft: draft);
        recovered.flush();
        expect(repo.getNote(note.id)!.preview, 'precious old');
        expect(repo.pendingEditorDrafts(), isEmpty);
        recovered.dispose();
      });
    },
  );

  test(
    'failed editor saves survive restart and recover without duplicating notes',
    () {
      fakeAsync((fake) {
        final dir = Directory.systemTemp.createTempSync(
          'notes draft recovery ',
        );
        final path = '${dir.path}/notes.db';
        final key = Uint8List.fromList(List.filled(32, 9));
        var db = AppDatabase.open(path, key: key);
        var diskRepo = NoteRepository(db);
        final note = diskRepo.createNote(body: json(Delta()..insert('old\n')));
        final editor = EditorSession(
          repo: diskRepo,
          noteId: note.id,
          autosaveDelay: const Duration(hours: 1),
          retryDelay: const Duration(hours: 1),
        );
        editor.quill.replaceText(
          0,
          0,
          'precious ',
          const TextSelection.collapsed(offset: 9),
        );
        db.execute('''
        CREATE TRIGGER fail_editor_update BEFORE UPDATE ON notes BEGIN
          SELECT RAISE(ABORT, 'injected write failure');
        END
      ''');
        editor.flush();
        expect(editor.status, SaveStatus.failed);
        expect(editor.recoveryCopySaved, isTrue);
        final draftId = diskRepo.pendingEditorDrafts().single.id;
        editor.dispose();
        diskRepo.dispose();
        db.close();

        db = AppDatabase.open(path, key: key);
        diskRepo = NoteRepository(db);
        final recoveredDraft = diskRepo.pendingEditorDrafts().single;
        expect(recoveredDraft.id, draftId);
        expect(recoveredDraft.body, contains('precious old'));
        expect(recoveredDraft.noteId, note.id);
        db.execute('DROP TRIGGER fail_editor_update');

        final recovered = EditorSession(
          repo: diskRepo,
          recoveredDraft: recoveredDraft,
          autosaveDelay: const Duration(hours: 1),
          retryDelay: const Duration(hours: 1),
        );
        expect(recovered.quill.document.toPlainText(), 'precious old\n');
        recovered.flush();
        expect(diskRepo.listNotes(), hasLength(1));
        expect(diskRepo.getNote(note.id)!.preview, 'precious old');
        expect(diskRepo.pendingEditorDrafts(), isEmpty);
        recovered.dispose();
        diskRepo.dispose();
        db.close();
        dir.deleteSync(recursive: true);
        fake.flushMicrotasks();
      });
    },
  );

  test('two recovery editors can consume a draft only once', () {
    final draft = PendingEditorDraft(
      id: 'single-consumer',
      noteId: null,
      folderId: null,
      title: 'Recovered once',
      body: json(Delta()..insert('one note only\n')),
      baseVv: VersionVector.empty.encode(),
      updatedAt: 50,
    );
    repo.savePendingEditorDraft(draft);
    final first = EditorSession(repo: repo, recoveredDraft: draft);
    final second = EditorSession(repo: repo, recoveredDraft: draft);

    first.flush();
    second.flush();

    expect(repo.listNotes(), hasLength(1));
    expect(repo.listNotes().single.title, 'Recovered once');
    expect(repo.pendingEditorDrafts(), isEmpty);
    expect(second.loadError, contains('already open'));
    expect(second.readOnly, isTrue);
    first.dispose();
    second.dispose();
    expect(repo.listNotes(), hasLength(1));
    expect(repo.pendingEditorDrafts(), isEmpty);
  });

  test('recovery loads the latest row after taking its lease', () {
    final oldSnapshot = PendingEditorDraft(
      id: 'stale-recovery-selection',
      noteId: null,
      folderId: null,
      title: 'Older list snapshot',
      body: json(Delta()..insert('older text\n')),
      baseVv: VersionVector.empty.encode(),
      updatedAt: 50,
    );
    repo.savePendingEditorDraft(oldSnapshot);
    final selectedFromList = repo.pendingEditorDrafts().single;
    repo.savePendingEditorDraft(
      PendingEditorDraft(
        id: oldSnapshot.id,
        noteId: null,
        folderId: null,
        title: 'Newer durable snapshot',
        body: json(Delta()..insert('newer text\n')),
        baseVv: VersionVector.empty.encode(),
        updatedAt: 51,
      ),
    );

    final recovered = EditorSession(
      repo: repo,
      recoveredDraft: selectedFromList,
    );
    expect(recovered.title.text, 'Newer durable snapshot');
    expect(recovered.quill.document.toPlainText(), 'newer text\n');
    recovered.flush();

    expect(repo.pendingEditorDrafts(), isEmpty);
    expect(repo.listNotes().single.title, 'Newer durable snapshot');
    expect(repo.listNotes().single.preview, 'newer text');
    recovered.dispose();
  });

  test('a transient latest-row read failure releases the draft lease', () {
    final draft = PendingEditorDraft(
      id: 'read-failure-releases-lease',
      noteId: null,
      folderId: null,
      title: 'Can retry opening',
      body: json(Delta()..insert('reopen after a read failure\n')),
      baseVv: VersionVector.empty.encode(),
      updatedAt: 50,
    );
    repo.savePendingEditorDraft(draft);
    final failingRepo = _FailOnceDraftLookupRepository(s.db);

    expect(
      () => EditorSession(repo: failingRepo, recoveredDraft: draft),
      throwsA(isA<StateError>()),
    );
    final recovered = EditorSession(repo: repo, recoveredDraft: draft);
    expect(recovered.readOnly, isFalse);
    recovered.flush();

    expect(repo.pendingEditorDrafts(), isEmpty);
    expect(repo.listNotes().single.title, 'Can retry opening');
    recovered.dispose();
    failingRepo.dispose();
  });

  test('a recovery editor cannot save after confirmed discard', () {
    final draft = PendingEditorDraft(
      id: 'discarded-while-open',
      noteId: null,
      folderId: null,
      title: 'Discard me',
      body: json(Delta()..insert('discarded text\n')),
      baseVv: VersionVector.empty.encode(),
      updatedAt: 50,
    );
    repo.savePendingEditorDraft(draft);
    final recovered = EditorSession(repo: repo, recoveredDraft: draft);

    repo.discardPendingEditorDraft(draft.id);
    recovered.flush();

    expect(recovered.recoveryDraftUnavailable, isTrue);
    expect(recovered.isTrashed, isFalse);
    expect(repo.pendingEditorDrafts(), isEmpty);
    expect(repo.listNotes(), isEmpty);
    recovered.dispose();
    expect(repo.pendingEditorDrafts(), isEmpty);
    expect(repo.listNotes(), isEmpty);
  });

  test('unavailable recovery cannot restore or delete its active original', () {
    final note = repo.createNote(title: 'Saved original');
    final draft = PendingEditorDraft(
      id: 'discarded-attached-draft',
      noteId: note.id,
      folderId: null,
      title: 'Unsaved edit',
      body: json(Delta()..insert('unsaved edit\n')),
      baseVv: note.contentVv.encode(),
      updatedAt: 50,
    );
    repo.savePendingEditorDraft(draft);
    final recovered = EditorSession(repo: repo, recoveredDraft: draft);

    repo.discardPendingEditorDraft(draft.id);
    recovered.flush();
    recovered.restoreFromTrash();

    expect(recovered.recoveryDraftUnavailable, isTrue);
    expect(recovered.isTrashed, isFalse);
    expect(recovered.readOnly, isTrue);
    expect(repo.getRecord(note.id)!.purged, isFalse);
    expect(repo.pendingEditorDrafts(), isEmpty);
    recovered.dispose();
  });

  test('serialization fallback does not recreate a confirmed discard', () {
    final draft = PendingEditorDraft(
      id: 'serialization-after-discard',
      noteId: null,
      folderId: null,
      title: 'Pending title',
      body: json(Delta()..insert('pending text\n')),
      baseVv: VersionVector.empty.encode(),
      updatedAt: 50,
    );
    repo.savePendingEditorDraft(draft);
    final recovered = _SerializationFailureSession(
      repo: repo,
      saveBarrier: EditorSaveBarrier(),
      recoveredDraft: draft,
      retryDelay: const Duration(hours: 1),
    );
    recovered.failSerialization = true;
    recovered.flush();
    expect(recovered.recoveryCopySaved, isTrue);

    repo.discardPendingEditorDraft(draft.id);
    recovered.flush();

    expect(recovered.recoveryDraftUnavailable, isTrue);
    expect(recovered.isTrashed, isFalse);
    expect(repo.pendingEditorDrafts(), isEmpty);
    expect(repo.listNotes(), isEmpty);
    recovered.dispose();
  });

  test('retrying a durable editor draft keeps a purged original deleted', () {
    final note = repo.createNote(title: 'Before deletion');
    final editor = EditorSession(
      repo: repo,
      noteId: note.id,
      autosaveDelay: const Duration(hours: 1),
      retryDelay: const Duration(hours: 1),
    );
    s.db.execute('''
      CREATE TRIGGER fail_editor_save BEFORE UPDATE ON notes BEGIN
        SELECT RAISE(ABORT, 'injected note write failure');
      END
    ''');
    editor.title.text = 'Unsaved after deletion';
    editor.quill.replaceText(
      0,
      0,
      'body kept on a new id',
      const TextSelection.collapsed(offset: 21),
    );
    editor.flush();
    expect(repo.pendingEditorDrafts(), hasLength(1));

    s.db.execute('DROP TRIGGER fail_editor_save');
    repo.purge([note.id]);
    editor.flush();

    expect(repo.getRecord(note.id)!.purged, isTrue);
    expect(repo.listNotes(), hasLength(1));
    expect(repo.listNotes().single.id, isNot(note.id));
    expect(repo.listNotes().single.title, 'Unsaved after deletion');
    expect(repo.listNotes().single.preview, 'body kept on a new id');
    expect(repo.pendingEditorDrafts(), isEmpty);
    editor.dispose();
  });

  test('clearing a failed new note removes its older recovery text', () {
    final editor = EditorSession(
      repo: repo,
      autosaveDelay: const Duration(hours: 1),
      retryDelay: const Duration(hours: 1),
    );
    editor.title.text = 'Stale title';
    editor.quill.replaceText(
      0,
      0,
      'stale body',
      const TextSelection.collapsed(offset: 10),
    );
    s.db.execute('''
      CREATE TRIGGER fail_new_note BEFORE INSERT ON notes BEGIN
        SELECT RAISE(ABORT, 'injected note write failure');
      END
    ''');
    editor.flush();
    expect(repo.pendingEditorDrafts().single.title, 'Stale title');

    editor.title.clear();
    editor.quill.replaceText(
      0,
      editor.quill.document.length - 1,
      '',
      const TextSelection.collapsed(offset: 0),
    );
    editor.flush();

    expect(repo.pendingEditorDrafts(), isEmpty);
    expect(repo.listNotes(), isEmpty);
    editor.dispose();
  });

  test(
    'purging an original during recovery preserves it and recovers as new',
    () {
      final original = repo.createNote(
        title: 'Original',
        body: json(Delta()..insert('saved body\n')),
      );
      final draft = PendingEditorDraft(
        id: 'purged-original-draft',
        noteId: original.id,
        folderId: null,
        title: 'Recovered title',
        body: json(Delta()..insert('recovered body\n')),
        baseVv: original.contentVv.encode(),
        updatedAt: 50,
      );
      repo.savePendingEditorDraft(draft);
      final recovered = EditorSession(repo: repo, recoveredDraft: draft);
      repo.purge([original.id]);

      recovered.flush();

      final rows = repo.listNotes();
      expect(rows, hasLength(1));
      expect(rows.single.id, isNot(original.id));
      expect(rows.single.title, 'Recovered title');
      expect(repo.getRecord(original.id)!.purged, isTrue);
      expect(repo.getNote(original.id), isNull);
      expect(repo.pendingEditorDrafts(), isEmpty);
      recovered.dispose();
    },
  );

  test('a disposed editor leaves recovery to an explicit user save', () {
    fakeAsync((fake) {
      final countingRepo = _CountingNoteRepository(s.db);
      final note = countingRepo.createNote(
        body: json(Delta()..insert('saved\n')),
      );
      final editor = EditorSession(
        repo: countingRepo,
        noteId: note.id,
        autosaveDelay: const Duration(hours: 1),
        retryDelay: const Duration(seconds: 3),
      );
      editor.quill.replaceText(
        0,
        0,
        'never abandon ',
        const TextSelection.collapsed(offset: 15),
      );
      s.db.execute('ALTER TABLE notes RENAME TO notes_away');
      editor.dispose();

      fake.elapse(const Duration(seconds: 30));
      expect(countingRepo.contentWriteAttempts, 1);
      final draft = countingRepo.pendingEditorDrafts().single;
      expect(draft.body, contains('never abandon saved'));
      s.db.execute('ALTER TABLE notes_away RENAME TO notes');
      expect(countingRepo.getNote(note.id)?.preview, 'saved');
      final recovered = EditorSession(
        repo: countingRepo,
        recoveredDraft: draft,
      );
      recovered.flush();
      expect(countingRepo.getNote(note.id)?.preview, 'never abandon saved');
      expect(countingRepo.pendingEditorDrafts(), isEmpty);
      recovered.dispose();
      countingRepo.dispose();
    });
  });

  test('discarding a draft is not undone by a disposed editor retry', () {
    fakeAsync((fake) {
      final retryRepo = _TransientRecoveryFailureRepository(s.db);
      final editor = EditorSession(
        repo: retryRepo,
        autosaveDelay: const Duration(hours: 1),
        retryDelay: const Duration(seconds: 3),
      );
      retryRepo.failDraftWrites = false;
      editor.title.text = 'Discarded title';
      editor.quill.replaceText(
        0,
        0,
        'discarded text',
        const TextSelection.collapsed(offset: 15),
      );
      editor.flush();
      final draftId = retryRepo.pendingEditorDrafts().single.id;
      editor.dispose();
      retryRepo.discardPendingEditorDraft(draftId);
      retryRepo.failContentWrites = false;
      fake.elapse(const Duration(seconds: 30));

      expect(retryRepo.listNotes(), isEmpty);
      expect(retryRepo.pendingEditorDrafts(), isEmpty);
      retryRepo.dispose();
    });
  });

  test(
    'dispose retries a serialized snapshot when recovery writes also fail',
    () {
      fakeAsync((fake) {
        final retryRepo = _TransientRecoveryFailureRepository(s.db);
        final note = retryRepo.createNote(body: json(Delta()..insert('old\n')));
        final editor = EditorSession(
          repo: retryRepo,
          noteId: note.id,
          autosaveDelay: const Duration(hours: 1),
          retryDelay: const Duration(seconds: 3),
        );
        editor.quill.replaceText(
          0,
          0,
          'typed ',
          const TextSelection.collapsed(offset: 6),
        );

        editor.flush();
        expect(editor.recoveryCopySaved, isFalse);
        expect(retryRepo.pendingEditorDrafts(), isEmpty);
        editor.dispose();
        expect(retryRepo.pendingEditorDrafts(), isEmpty);

        retryRepo.failContentWrites = false;
        retryRepo.failDraftWrites = false;
        fake.elapse(const Duration(seconds: 3));
        fake.flushMicrotasks();
        expect(retryRepo.getNote(note.id)?.preview, 'old');
        final draft = retryRepo.pendingEditorDrafts().single;
        expect(draft.body, contains('typed old'));
        final recovered = EditorSession(repo: retryRepo, recoveredDraft: draft);
        recovered.flush();
        expect(retryRepo.getNote(note.id)?.preview, 'typed old');
        expect(retryRepo.pendingEditorDrafts(), isEmpty);
        recovered.dispose();
        retryRepo.dispose();
      });
    },
  );

  test(
    'disposed editor retries past 2000 failures until its draft is durable',
    () {
      fakeAsync((fake) {
        final retryRepo = _RetryAfterManyFailuresRepository(s.db);
        final editor = EditorSession(
          repo: retryRepo,
          autosaveDelay: const Duration(hours: 1),
          retryDelay: const Duration(milliseconds: 1),
        );
        editor.title.text = 'Recovered after storage returns';
        editor.quill.replaceText(
          0,
          0,
          'durable text',
          const TextSelection.collapsed(offset: 12),
        );
        editor.flush();
        editor.dispose();
        expect(retryRepo.pendingEditorDrafts(), isEmpty);

        fake.elapse(const Duration(days: 2));
        fake.flushMicrotasks();

        expect(retryRepo.handoffAttempts, greaterThan(2000));
        expect(retryRepo.pendingEditorDrafts(), hasLength(1));
        expect(
          retryRepo.pendingEditorDrafts().single.title,
          'Recovered after storage returns',
        );
        retryRepo.dispose();
      });
    },
  );

  test('serialization failure keeps latest plain text and unregisters', () {
    fakeAsync((fake) {
      final barrier = EditorSaveBarrier();
      final note = repo.createNote(
        body: json(
          Delta()
            ..insert('completed')
            ..insert('\n', {'list': 'checked'})
            ..insert('old\n'),
        ),
      );
      final editor = _SerializationFailureSession(
        repo: repo,
        saveBarrier: barrier,
        noteId: note.id,
        retryDelay: const Duration(hours: 1),
      );
      editor.quill.replaceText(
        0,
        0,
        'kept draft ',
        const TextSelection.collapsed(offset: 12),
      );
      s.db.execute('ALTER TABLE notes RENAME TO notes_away');
      editor.flush();
      final previous = repo.pendingEditorDrafts().single;
      expect(previous.body, contains('completed'));
      expect(previous.body, contains('kept draft old'));

      editor.title.text = 'Latest title';
      final end = editor.quill.document.length - 1;
      editor.quill.replaceText(
        end,
        0,
        ' latest words',
        TextSelection.collapsed(offset: end + 13),
      );
      editor.failSerialization = true;
      editor.flush();
      final fallback = repo.pendingEditorDrafts().single;
      expect(fallback.title, 'Latest title');
      expect(fallback.body, contains('completed'));
      expect(fallback.body, contains('latest words'));
      expect(editor.recoveryCopyIsPlainTextFallback, isTrue);
      expect(editor.recoveryCopyCurrent, isTrue);

      expect(editor.dispose, returnsNormally);
      expect(repo.pendingEditorDrafts().single.body, fallback.body);
      s.db.execute('ALTER TABLE notes_away RENAME TO notes');

      var prepared = false;
      barrier.prepare().then((_) => prepared = true);
      fake.flushMicrotasks();
      expect(
        prepared,
        isTrue,
        reason: 'dispose must unregister after serialization fails',
      );
      barrier.release();
    });
  });
}
