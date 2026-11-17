import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/migrations.dart';
import 'package:notes/data/note_repository.dart';

Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('notes db test '));
  tearDown(() => dir.deleteSync(recursive: true));
  String path([String name = 'notes.db']) => '${dir.path}/$name';

  test('encrypted file: not plaintext, wrong or missing key refused, file untouched', () {
    final db = AppDatabase.open(path(), key: key(1));
    NoteRepository(
      db,
    ).createNote(title: 'secret title', body: '[{"insert":"secret body\\n"}]');
    db.close();

    final bytes = File(path()).readAsBytesSync();
    expect(String.fromCharCodes(bytes.take(15)), isNot('SQLite format 3'));
    expect(String.fromCharCodes(bytes).contains('secret'), isFalse);

    expect(
      () => AppDatabase.open(path(), key: key(2)),
      throwsA(isA<DatabaseUnreadableException>()),
    );
    expect(
      () => AppDatabase.open(path()),
      throwsA(isA<DatabaseUnreadableException>()),
    );
    expect(
      File(path()).readAsBytesSync(),
      bytes,
      reason: 'failed opens must not modify the file',
    );

    final again = AppDatabase.open(path(), key: key(1));
    expect(NoteRepository(again).listNotes().single.title, 'secret title');
    again.close();
  });

  test('device id, clock and sequence survive a restart', () {
    var db = AppDatabase.open(path(), wallClock: () => 5000);
    final device = db.deviceId;
    final repo = NoteRepository(db);
    repo.createNote(title: 'a');
    repo.createNote(title: 'b');
    final seq = db.currentSeq;
    final hlc = db.clock.last;
    db.close();

    // Wall clock went backwards across the restart: stamps must still advance.
    db = AppDatabase.open(path(), wallClock: () => 10);
    expect(db.deviceId, device);
    expect(db.currentSeq, seq);
    expect(db.clock.last, hlc);
    NoteRepository(db).createNote(title: 'c');
    expect(db.clock.last > hlc, isTrue);
    expect(db.currentSeq, seq + 1);
    db.close();
  });

  test(
    'a failing transaction rolls back everything, including the sequence',
    () {
      final db = AppDatabase.open(null);
      final repo = NoteRepository(db);
      repo.createNote(title: 'kept');
      final seq = db.currentSeq;
      var notified = 0;
      db.changes.addListener(() => notified++);
      expect(
        () => db.transaction(() {
          repo.createNote(title: 'lost 1');
          repo.createNote(title: 'lost 2');
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(repo.listNotes().map((n) => n.title), ['kept']);
      expect(db.currentSeq, seq);
      expect(notified, 0);
      repo.createNote(title: 'after');
      expect(notified, 1);
      expect(repo.listNotes().length, 2);
      db.close();
    },
  );

  test(
    'a write interrupted before commit leaves the previous state on disk',
    () {
      final db = AppDatabase.open(path(), key: key(3));
      final repo = NoteRepository(db);
      final note = repo.createNote(title: 'v1', body: '[{"insert":"one\\n"}]');
      // Simulate a process killed mid-save: begin, write, never commit.
      db.raw.execute('BEGIN IMMEDIATE');
      db.raw.execute("UPDATE notes SET title = 'v2 partial' WHERE id = ?", [
        note.id,
      ]);
      // A second connection (the "next launch") sees only committed data.
      final next = AppDatabase.open(path(), key: key(3));
      expect(NoteRepository(next).getNote(note.id)!.title, 'v1');
      next.close();
      db.raw.execute('ROLLBACK');
      db.close();
    },
  );

  test('upgrade: old schema is migrated, data kept, backup written first', () {
    // Version 1 is the real schema; pretend a later release adds a table.
    final v1 = AppDatabase.open(path(), key: key(4));
    final id = NoteRepository(v1).createNote(title: 'before upgrade').id;
    v1.close();

    final next = [
      ...migrations,
      ['CREATE TABLE added_later (x TEXT)'],
    ];
    final v2 = AppDatabase.open(path(), key: key(4), schema: next);
    expect(v2.raw.userVersion, migrations.length + 1);
    expect(NoteRepository(v2).getNote(id)!.title, 'before upgrade');
    v2.execute("INSERT INTO added_later VALUES ('ok')");
    v2.close();

    final backup = '${path()}.pre-v${next.length}.bak';
    expect(File(backup).existsSync(), isTrue);
    final old = AppDatabase.open(backup, key: key(4));
    expect(old.raw.userVersion, migrations.length);
    expect(NoteRepository(old).getNote(id)!.title, 'before upgrade');
    old.close();
    expect(
      () => AppDatabase.open(backup, key: key(9)),
      throwsA(isA<DatabaseUnreadableException>()),
      reason: 'the backup must be encrypted too',
    );
  });

  test('a failing migration changes nothing', () {
    AppDatabase.open(path()).close();
    final broken = [
      ...migrations,
      ['CREATE TABLE half_done (x TEXT)', 'THIS IS NOT SQL'],
    ];
    expect(() => AppDatabase.open(path(), schema: broken), throwsA(anything));
    final db = AppDatabase.open(path());
    expect(db.raw.userVersion, migrations.length);
    expect(
      db.select("SELECT name FROM sqlite_master WHERE name = 'half_done'"),
      isEmpty,
    );
    db.close();
  });

  test('a database from a newer app version is refused, not downgraded', () {
    final db = AppDatabase.open(path());
    db.raw.userVersion = migrations.length + 5;
    db.close();
    expect(
      () => AppDatabase.open(path()),
      throwsA(isA<DatabaseTooNewException>()),
    );
  });

  test('snapshot is a complete, independently openable copy', () {
    final db = AppDatabase.open(path(), key: key(5));
    final id = NoteRepository(db).createNote(title: 'snap').id;
    db.snapshotTo(path('backups/copy.db'));
    NoteRepository(db).purge([id]);
    db.close();
    final copy = AppDatabase.open(path('backups/copy.db'), key: key(5));
    expect(NoteRepository(copy).getNote(id)!.title, 'snap');
    copy.close();
  });
}
