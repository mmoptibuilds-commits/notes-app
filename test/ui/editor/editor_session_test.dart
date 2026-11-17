import 'dart:convert';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/models.dart' show NoteScope;
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/checklist_projection.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_session.dart';

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
        s.db.execute('ALTER TABLE notes_away RENAME TO notes');
        fake.elapse(const Duration(seconds: 4));
        expect(repo.getNote(note.id)!.preview, 'precious old');
      });
    },
  );
}
