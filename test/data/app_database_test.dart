import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/editor_draft.dart';
import 'package:notes/data/migrations.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/core/version_vector.dart';

Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));

Future<void> _waitForFiles(List<File> files, List<Process> processes) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (files.any((file) => !file.existsSync())) {
    if (DateTime.now().isAfter(deadline)) {
      for (final process in processes) {
        process.kill();
      }
      fail('worker processes did not become ready');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

String _flutterBinary() {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  return '$root/bin/flutter';
}

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

  test(
    'pending editor drafts are encrypted and survive a database restart',
    () {
      var db = AppDatabase.open(path(), key: key(8));
      var repo = NoteRepository(db);
      repo.savePendingEditorDraft(
        PendingEditorDraft(
          id: 'draft-id',
          noteId: null,
          folderId: null,
          title: 'private draft title',
          body: '[{"insert":"private draft body\\n"}]',
          baseVv: VersionVector.empty.encode(),
          updatedAt: 50,
        ),
      );
      db.close();

      final bytes = File(path()).readAsBytesSync();
      expect(String.fromCharCodes(bytes).contains('private draft'), isFalse);
      db = AppDatabase.open(path(), key: key(8));
      repo = NoteRepository(db);
      expect(repo.pendingEditorDrafts().single.title, 'private draft title');
      expect(
        repo.pendingEditorDrafts().single.body,
        contains('private draft body'),
      );
      db.close();
    },
  );

  test('note commit and recovery-row removal are one transaction', () {
    final db = AppDatabase.open(path());
    final repo = NoteRepository(db);
    final draft = PendingEditorDraft(
      id: 'draft-id',
      noteId: null,
      folderId: null,
      title: 'Recovered once',
      body: '[{"insert":"kept body\\n"}]',
      baseVv: VersionVector.empty.encode(),
      updatedAt: 50,
    );
    repo.savePendingEditorDraft(draft);
    db.execute('''
      CREATE TRIGGER fail_note_insert BEFORE INSERT ON notes BEGIN
        SELECT RAISE(ABORT, 'injected note write failure');
      END
    ''');

    expect(
      () => repo.writeEditorContent(
        draftId: draft.id,
        noteId: draft.noteId,
        title: draft.title,
        body: draft.body,
        base: VersionVector.decode(draft.baseVv),
        folderId: draft.folderId,
      ),
      throwsA(anything),
    );
    expect(repo.pendingEditorDrafts().single.id, draft.id);
    expect(repo.listNotes(), isEmpty);

    db.execute('DROP TRIGGER fail_note_insert');
    final saved = repo.writeEditorContent(
      draftId: draft.id,
      noteId: draft.noteId,
      title: draft.title,
      body: draft.body,
      base: VersionVector.decode(draft.baseVv),
      folderId: draft.folderId,
    );
    expect(repo.getNote(saved.noteId)?.title, 'Recovered once');
    expect(repo.pendingEditorDrafts(), isEmpty);
    db.close();
  });

  test(
    'recovering a stale draft preserves the newer note as a conflict copy',
    () {
      final db = AppDatabase.open(path());
      final repo = NoteRepository(db);
      final original = repo.createNote(
        title: 'Base',
        body: '[{"insert":"base\\n"}]',
      );
      final latest = '[{"insert":"changed on another device\\n"}]';
      repo.saveContent(
        original.id,
        title: 'Remote edit',
        body: latest,
        base: original.contentVv,
      );
      final draft = PendingEditorDraft(
        id: 'stale-draft',
        noteId: original.id,
        folderId: null,
        title: 'Local draft',
        body: '[{"insert":"precious local text\\n"}]',
        baseVv: original.contentVv.encode(),
        updatedAt: 51,
      );
      repo.savePendingEditorDraft(draft);

      final result = repo.writeEditorContent(
        draftId: draft.id,
        noteId: draft.noteId,
        title: draft.title,
        body: draft.body,
        base: VersionVector.decode(draft.baseVv),
      );
      expect(result.conflictCopyId, isNotNull);
      expect(repo.getNote(original.id)?.title, 'Local draft');
      expect(repo.getNote(result.conflictCopyId!)?.title, 'Remote edit');
      expect(repo.pendingEditorDrafts(), isEmpty);
      db.close();
    },
  );

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

  test('two open connections allocate unique sequences and clocks', () {
    final first = AppDatabase.open(path(), wallClock: () => 5000);
    final second = AppDatabase.open(path(), wallClock: () => 5000);
    final a = NoteRepository(first).createNote(title: 'first');
    final b = NoteRepository(second).createNote(title: 'second');

    expect(
      first
          .select('SELECT local_seq FROM notes ORDER BY title')
          .map((row) => row['local_seq']),
      [1, 2],
    );
    final notes = NoteRepository(first);
    expect(
      notes.getRecord(a.id)!.contentHlc,
      lessThan(notes.getRecord(b.id)!.contentHlc),
    );
    expect(first.clock.last, lessThan(second.clock.last));
    second.close();
    first.close();
  });

  test(
    'separate processes serialize writes and refresh sequence metadata',
    () async {
      final readyA = File(path('ready-a'));
      final readyB = File(path('ready-b'));
      final release = File(path('release'));
      final flutter = _flutterBinary();
      Future<Process> startWriter(String title, File ready) => Process.start(
        flutter,
        [
          'test',
          '--no-pub',
          'test/data/sequence_writer_process_test.dart',
          '--reporter',
          'expanded',
        ],
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          'NOTES_PROCESS_DB': path(),
          'NOTES_PROCESS_READY': ready.path,
          'NOTES_PROCESS_RELEASE': release.path,
          'NOTES_PROCESS_TITLE': title,
        },
      );
      final first = await startWriter('process A', readyA);
      unawaited(first.stdout.drain<void>());
      unawaited(first.stderr.drain<void>());
      await _waitForFiles([readyA], [first]);
      final second = await startWriter('process B', readyB);
      unawaited(second.stdout.drain<void>());
      unawaited(second.stderr.drain<void>());
      try {
        await _waitForFiles([readyB], [first, second]);
        release.writeAsStringSync('go');
        expect(await first.exitCode, 0);
        expect(await second.exitCode, 0);
      } finally {
        release.writeAsStringSync('go');
        first.kill();
        second.kill();
      }

      final check = AppDatabase.open(path(), wallClock: () => 5000);
      final rows = check.select(
        'SELECT local_seq, content_hlc FROM notes ORDER BY local_seq',
      );
      expect(rows.map((row) => row['local_seq']), [1, 2]);
      expect(rows[0]['content_hlc'], isNot(rows[1]['content_hlc']));
      check.close();
    },
  );

  test('concurrent process snapshots do not replace one another', () async {
    final db = AppDatabase.open(path());
    final note = NoteRepository(db).createNote(title: 'snapshot source');
    db.close();

    final target = path('snapshots/shared.db');
    final release = File(path('snapshot-release'));
    final readyA = File(path('snapshot-ready-a'));
    final readyB = File(path('snapshot-ready-b'));
    final resultA = File(path('snapshot-result-a'));
    final resultB = File(path('snapshot-result-b'));
    final flutter = _flutterBinary();

    Future<Process> startSnapshot(File ready, File result) => Process.start(
      flutter,
      [
        'test',
        '--no-pub',
        'test/data/sequence_writer_process_test.dart',
        '--reporter',
        'expanded',
      ],
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'NOTES_PROCESS_DB': path(),
        'NOTES_PROCESS_SNAPSHOT_TARGET': target,
        'NOTES_PROCESS_READY': ready.path,
        'NOTES_PROCESS_RELEASE': release.path,
        'NOTES_PROCESS_RESULT': result.path,
      },
    );

    final first = await startSnapshot(readyA, resultA);
    unawaited(first.stdout.drain<void>());
    unawaited(first.stderr.drain<void>());
    await _waitForFiles([readyA], [first]);
    final second = await startSnapshot(readyB, resultB);
    unawaited(second.stdout.drain<void>());
    unawaited(second.stderr.drain<void>());
    try {
      await _waitForFiles([readyB], [first, second]);
      release.writeAsStringSync('go');
      expect(await first.exitCode, 0);
      expect(await second.exitCode, 0);
      final outcomes = [resultA.readAsStringSync(), resultB.readAsStringSync()]
        ..sort();
      expect(outcomes, ['created', 'exists']);
    } finally {
      release.writeAsStringSync('go');
      first.kill();
      second.kill();
    }

    final copy = AppDatabase.open(target);
    expect(NoteRepository(copy).getNote(note.id)?.title, 'snapshot source');
    copy.close();
  });

  test('a crashed process leaves no stale database open lock', () async {
    final db = AppDatabase.open(path());
    db.close();
    final ready = File(path('lock-ready'));
    final release = File(path('lock-release'));
    final pidFile = File(path('lock-pid'));
    final holder = await Process.start(
      _flutterBinary(),
      [
        'test',
        '--no-pub',
        'test/data/sequence_writer_process_test.dart',
        '--reporter',
        'expanded',
      ],
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'NOTES_PROCESS_DB': path(),
        'NOTES_PROCESS_READY': ready.path,
        'NOTES_PROCESS_RELEASE': release.path,
        'NOTES_PROCESS_PID': pidFile.path,
        'NOTES_PROCESS_HOLD_OPEN_LOCK': 'true',
      },
    );
    unawaited(holder.stdout.drain<void>());
    unawaited(holder.stderr.drain<void>());
    await _waitForFiles([ready], [holder]);
    final childPid = int.parse(pidFile.readAsStringSync());
    Process.killPid(childPid, ProcessSignal.sigkill);
    expect(await holder.exitCode, isNot(0));

    final reopened = AppDatabase.open(path());
    expect(reopened.raw.userVersion, schemaVersion);
    reopened.close();
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

  test('only one process can edit a recovery draft at a time', () async {
    final db = AppDatabase.open(path());
    final repo = NoteRepository(db);
    const draftId = 'cross-process-recovery-lock';
    final ready = File(path('draft-lock-ready'));
    final release = File(path('draft-lock-release'));
    final worker = await Process.start(
      _flutterBinary(),
      [
        'test',
        '--no-pub',
        'test/data/sequence_writer_process_test.dart',
        '--reporter',
        'expanded',
      ],
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'NOTES_PROCESS_DB': path(),
        'NOTES_PROCESS_DRAFT_LOCK_ID': draftId,
        'NOTES_PROCESS_READY': ready.path,
        'NOTES_PROCESS_RELEASE': release.path,
      },
    );
    unawaited(worker.stdout.drain<void>());
    unawaited(worker.stderr.drain<void>());
    try {
      await _waitForFiles([ready], [worker]);
      expect(repo.acquireEditorDraftLease(draftId), isNull);
    } finally {
      release.writeAsStringSync('go');
    }
    expect(await worker.exitCode, 0);
    final lease = repo.acquireEditorDraftLease(draftId);
    expect(lease, isNotNull);
    lease!.release();
    repo.dispose();
    db.close();
  });

  test('a database from a newer app version is refused, not downgraded', () {
    final db = AppDatabase.open(path());
    db.raw.userVersion = migrations.length + 5;
    db.close();
    try {
      AppDatabase.open(path());
      fail('expected a newer schema to be refused');
    } on DatabaseTooNewException catch (e) {
      expect(e.databasePath, path());
      expect(
        e.recoveryBackupPath,
        '${path()}.pre-v${migrations.length + 5}.bak',
      );
    }
  });

  test('failed migration backup replacement preserves the prior good copy', () {
    final old = AppDatabase.open(
      path(),
      key: key(6),
      schema: migrations.sublist(0, 4),
    );
    final id = NoteRepository(old).createNote(title: 'before migration').id;
    final backupPath = '${path()}.pre-v${migrations.length}.bak';
    old.snapshotTo(backupPath);
    old.close();
    final before = File(backupPath).readAsBytesSync();

    expect(
      () => AppDatabase.open(
        path(),
        key: key(6),
        beforeMigrationBackupReplace: (_) =>
            throw StateError('simulated swap failure'),
      ),
      throwsStateError,
    );
    expect(File(backupPath).readAsBytesSync(), before);
    final preserved = AppDatabase.open(
      backupPath,
      key: key(6),
      schema: migrations.sublist(0, 4),
    );
    expect(NoteRepository(preserved).getNote(id)?.title, 'before migration');
    preserved.close();

    final upgraded = AppDatabase.open(path(), key: key(6));
    expect(upgraded.raw.userVersion, migrations.length);
    upgraded.close();
    final replaced = AppDatabase.open(
      backupPath,
      key: key(6),
      schema: migrations.sublist(0, 4),
    );
    expect(NoteRepository(replaced).getNote(id)?.title, 'before migration');
    replaced.close();
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

  test('pre-import snapshots stay bounded and retain verified copies', () {
    final db = AppDatabase.open(path(), key: key(7));
    final id = NoteRepository(db).createNote(title: 'recoverable').id;
    final backups = Directory(path('backups'));
    for (var i = 0; i < 9; i++) {
      db.snapshotTo('${backups.path}/before-import-$i.db');
    }
    for (var i = 0; i < 7; i++) {
      File('${backups.path}/before-import-empty-$i.db').writeAsBytesSync([]);
    }
    db.snapshotTo('${backups.path}/before-import-after-empty.db');
    final retained = backups
        .listSync()
        .whereType<File>()
        .where(
          (file) =>
              file.uri.pathSegments.last.startsWith('before-import-') &&
              !file.uri.pathSegments.last.contains('-empty-') &&
              file.path.endsWith('.db'),
        )
        .toList();
    expect(retained, hasLength(7));
    for (final file in retained) {
      final copy = AppDatabase.open(file.path, key: key(7));
      expect(NoteRepository(copy).getNote(id)?.title, 'recoverable');
      copy.close();
    }
    final last = retained.last;
    final contents = last.readAsBytesSync();
    expect(() => db.snapshotTo(last.path), throwsA(anything));
    expect(last.readAsBytesSync(), contents);
    db.close();
  });
}
