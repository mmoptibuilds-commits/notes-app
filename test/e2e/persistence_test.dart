import 'dart:convert';
import 'dart:io';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/migrations.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/checklist_projection.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_session.dart';

/// "Create, edit, autosave, restart and reopen a note", against the real
/// on-disk encrypted database and key file (as `bootstrap` sets them up),
/// not in-memory stand-ins.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('notes e2e '));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'a note typed into the editor survives closing and reopening the app',
    () async {
      var app = await bootstrap(dataDir: dir.path);
      final first = EditorSession(
        repo: app.notes,
        autosaveDelay: const Duration(milliseconds: 20),
      );
      first.title.text = 'Weekend plan';
      first.quill.replaceText(
        0,
        0,
        'Pick up the parcel',
        const TextSelection.collapsed(offset: 18),
      );
      await Future<void>.delayed(
        const Duration(milliseconds: 150),
      ); // autosave fires
      final id = first.noteId;
      expect(id, isNotNull, reason: 'autosave must have stored the note');
      // Format and check items, edit again.
      first.quill.formatText(0, 18, Attribute.bold);
      first.quill.replaceText(
        18,
        0,
        '\nBuy milk\nCall mum',
        const TextSelection.collapsed(offset: 36),
      );
      first.quill.formatText(36, 0, Attribute.unchecked);
      first.quill.formatText(27, 0, Attribute.unchecked);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      first.quill.formatText(27, 0, Attribute.checked); // tick "Buy milk"
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final before = app.notes.getNote(id!)!;
      first.dispose();
      app.close();

      // "Restart": a brand-new process would run exactly this.
      app = await bootstrap(dataDir: dir.path);
      addTearDown(app.close);
      final after = app.notes.getNote(id)!;
      expect(after.title, 'Weekend plan');
      expect(
        after.body,
        before.body,
        reason: 'content identical after restart',
      );
      final saved = deltaFromBody(after.body);
      final attrs = [
        for (final op in saved.toList())
          if (op.attributes != null) op.attributes!,
      ];
      expect(
        attrs.any((a) => a['bold'] == true),
        isTrue,
        reason: 'formatting survives',
      );
      expect(
        attrs.where((a) => a['list'] == 'checked').length,
        1,
        reason: 'checklist state survives',
      );
      expect(attrs.where((a) => a['list'] == 'unchecked').length, 1);
      // Reopening in the editor shows the completed item in its section.
      final reopened = EditorSession(repo: app.notes, noteId: id);
      expect(reopened.completed.map((c) => c.text), ['Buy milk']);
      expect(app.notes.listNotes().single.id, id);
      reopened.dispose();
    },
  );

  test(
    'a restart that cannot find the key refuses to open, and changes nothing',
    () async {
      final app = await bootstrap(dataDir: dir.path);
      app.notes.createNote(title: 'precious');
      app.close();
      final dbFile = File('${dir.path}/notes.db');
      final before = dbFile.readAsBytesSync();
      File('${dir.path}/dev.key').deleteSync(); // key lost
      await expectLater(
        bootstrap(dataDir: dir.path),
        throwsA(isA<DatabaseKeyMissingException>()),
      );
      expect(
        dbFile.readAsBytesSync(),
        before,
        reason: 'the database file must be untouched',
      );
      expect(
        File('${dir.path}/dev.key').existsSync(),
        isFalse,
        reason: 'no new key may be invented over an existing database',
      );
    },
  );

  test(
    'a database written with another key is refused, not overwritten',
    () async {
      final app = await bootstrap(dataDir: dir.path);
      app.notes.createNote(title: 'precious');
      app.close();
      final bytes = File('${dir.path}/notes.db').readAsBytesSync();
      File('${dir.path}/dev.key')
          .writeAsStringSync(base64Encode(List.filled(32, 1)));
      await expectLater(
        bootstrap(dataDir: dir.path),
        throwsA(isA<DatabaseUnreadableException>()),
      );
      expect(File('${dir.path}/notes.db').readAsBytesSync(), bytes);
    },
  );

  test('upgrading: a version-1 database from an earlier build opens, migrates, and keeps its notes', () async {
    // Simulate the previous release: build the v1 schema with the real key.
    final app0 = await bootstrap(dataDir: dir.path);
    app0.close();
    final key = base64Decode(
      File('${dir.path}/dev.key').readAsStringSync().trim(),
    );
    File('${dir.path}/notes.db').deleteSync();
    for (final ext in ['-wal', '-shm']) {
      final f = File('${dir.path}/notes.db$ext');
      if (f.existsSync()) f.deleteSync();
    }
    final old = AppDatabase.open(
      '${dir.path}/notes.db',
      key: key,
      schema: migrations.sublist(0, 1),
    );
    final repoOld = NoteRepository(old);
    final id = repoOld
        .createNote(
          title: 'from the old version',
          body: jsonEncode((Delta()..insert('kept\n')).toJson()),
        )
        .id;
    old.close();
    final app = await bootstrap(dataDir: dir.path);
    addTearDown(app.close);
    expect(app.notes.getNote(id)!.title, 'from the old version');
    expect(app.db.raw.userVersion, greaterThan(1));
    expect(
      Directory(dir.path).listSync().any((f) => f.path.contains('.pre-v')),
      isTrue,
      reason: 'a backup is written before migrating',
    );
  });
}
