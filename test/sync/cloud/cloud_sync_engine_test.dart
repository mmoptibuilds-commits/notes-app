import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/cloud/cloud_sync_engine.dart';
import 'package:notes/sync/cloud/record_digest.dart';
import 'package:notes/sync/cloud/cloud_api.dart';

import '../../support/fake_cloud_server.dart';

void main() {
  test('local note pushes once and a second device pulls it', () async {
    final dbA = AppDatabase.open(null);
    final dbB = AppDatabase.open(null);
    addTearDown(dbA.close);
    addTearDown(dbB.close);
    final a = NoteRepository(dbA);
    final b = NoteRepository(dbB);
    a.createNote(
      title: 'synthetic',
      id: '00000000-0000-4000-8000-000000000001',
    );
    final server = FakeCloudServer();
    dbA.transaction(() => dbA.setMeta('cloud.library_id', server.libraryId));
    dbB.transaction(() => dbB.setMeta('cloud.library_id', server.libraryId));

    await CloudSyncEngine(a, server).sync();
    expect(server.records, hasLength(1));
    await CloudSyncEngine(b, server).sync();
    expect(
      b.getNote('00000000-0000-4000-8000-000000000001')?.title,
      'synthetic',
    );
    expect(dbB.getMeta('cloud.pull_seq'), '1');
  });

  test('lost push response is safe to retry by digest', () async {
    final db = AppDatabase.open(null);
    addTearDown(db.close);
    final repo = NoteRepository(db);
    repo.createNote(
      title: 'synthetic',
      id: '00000000-0000-4000-8000-000000000002',
    );
    final server = FakeCloudServer()..dropNextPushResponse = true;
    db.transaction(() => db.setMeta('cloud.library_id', server.libraryId));
    final engine = CloudSyncEngine(repo, server);
    await expectLater(engine.sync(), throwsA(anything));
    await engine.sync();
    expect(server.records, hasLength(1));
    expect(
      server.records.values.single.digest,
      recordDigest(repo.getRecord('00000000-0000-4000-8000-000000000002')!),
    );
  });

  test('a missing server row resets its revision and is reinserted', () async {
    final db = AppDatabase.open(null);
    addTearDown(db.close);
    final repo = NoteRepository(db);
    const id = '00000000-0000-4000-8000-000000000012';
    repo.createNote(title: 'before', id: id);
    final server = FakeCloudServer();
    db.transaction(() => db.setMeta('cloud.library_id', server.libraryId));
    final engine = CloudSyncEngine(repo, server);

    await engine.sync();
    server.records.remove(
      'note:$id',
    ); // Model a server row lost after a local ack.
    db.transaction(() => db.setMeta('cloud.pull_seq', '${server.seq}'));
    final current = repo.getNote(id)!;
    repo.saveContent(
      id,
      title: 'after',
      body: current.body,
      base: current.contentVv,
    );

    await engine.sync();

    expect(server.records['note:$id']?.row['title'], 'after');
    expect(server.records['note:$id']?.rev, 1);
    expect(
      db.select("SELECT id FROM cloud_notes WHERE kind='note' AND id=?", [id]),
      hasLength(1),
    );
  });

  test(
    'future remote HLC stops sync without advancing cursor or clock',
    () async {
      final db = AppDatabase.open(null);
      addTearDown(db.close);
      final repo = NoteRepository(db);
      final sourceDb = AppDatabase.open(null);
      addTearDown(sourceDb.close);
      final source = NoteRepository(sourceDb);
      source.createNote(
        title: 'synthetic',
        id: '00000000-0000-4000-8000-000000000003',
      );
      final row = source
          .getRecord('00000000-0000-4000-8000-000000000003')!
          .toJson();
      final future =
          DateTime.now().millisecondsSinceEpoch +
          const Duration(days: 3).inMilliseconds;
      row['contentHlc'] =
          '${future.toRadixString(16).padLeft(12, '0')}0000-hostile';
      final server = FakeCloudServer()..seq = 1;
      server.records['note:${row['id']}'] = CloudRecord(
        kind: 'note',
        id: row['id'] as String,
        rev: 1,
        seq: 1,
        digest: recordDigest(row),
        row: row,
      );
      db.transaction(() => db.setMeta('cloud.library_id', server.libraryId));
      db.transaction(() => db.setMeta('cloud.pull_seq', '0'));

      await expectLater(
        CloudSyncEngine(repo, server).sync(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.message,
            'message',
            contains("This device's or another device's clock looks wrong"),
          ),
        ),
      );
      expect(db.getMeta('cloud.pull_seq'), '0');
      expect(repo.getRecord(row['id'] as String), isNull);
      expect(db.clock.last.millis, lessThan(future));
    },
  );

  test(
    'malformed row is quarantined without partially writing the note',
    () async {
      final db = AppDatabase.open(null);
      addTearDown(db.close);
      final repo = NoteRepository(db);
      final server = FakeCloudServer()..seq = 1;
      final row = <String, Object?>{'id': 'not-a-note', 'body': '['};
      server.records['note:not-a-note'] = CloudRecord(
        kind: 'note',
        id: 'not-a-note',
        rev: 1,
        seq: 1,
        digest: recordDigest(row),
        row: row,
      );
      db.transaction(() => db.setMeta('cloud.library_id', server.libraryId));

      await CloudSyncEngine(repo, server).sync();

      expect(db.select('SELECT id FROM notes'), isEmpty);
      expect(
        db.select("SELECT id FROM quarantine WHERE peer_id='cloud'"),
        hasLength(1),
      );
      expect(db.getMeta('cloud.pull_seq'), '1');
    },
  );

  test('push conflict applies current rows and converges after an interleaved push', () async {
    final dbA = AppDatabase.open(null);
    final dbB = AppDatabase.open(null);
    addTearDown(dbA.close);
    addTearDown(dbB.close);
    final a = NoteRepository(dbA);
    final b = NoteRepository(dbB);
    final server = FakeCloudServer();
    for (final db in [dbA, dbB]) {
      db.transaction(() => db.setMeta('cloud.library_id', server.libraryId));
    }
    final created = a.createNote(
      title: 'base',
      id: '00000000-0000-4000-8000-000000000004',
    );
    final engineA = CloudSyncEngine(a, server);
    final engineB = CloudSyncEngine(b, server);
    await engineA.sync();
    await engineB.sync();
    final onA = a.getNote(created.id)!;
    final onB = b.getNote(created.id)!;
    a.saveContent(
      created.id,
      title: 'edited on A',
      body: onA.body,
      base: onA.contentVv,
    );
    b.saveContent(
      created.id,
      title: 'edited on B',
      body: onB.body,
      base: onB.contentVv,
    );
    server.beforeNextPush = engineB.sync;

    await engineA.sync();
    await engineB.sync();

    expect(server.records, hasLength(2));
    expect(a.getRecord(created.id), isNotNull);
    expect(b.getRecord(created.id), isNotNull);
  });

  test(
    'three-way merge clock is later than both remote and local versions',
    () async {
      final dbA = AppDatabase.open(null);
      final dbB = AppDatabase.open(null);
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final a = NoteRepository(dbA);
      final b = NoteRepository(dbB);
      final server = FakeCloudServer();
      for (final db in [dbA, dbB]) {
        db.transaction(() => db.setMeta('cloud.library_id', server.libraryId));
      }
      const id = '00000000-0000-4000-8000-000000000005';
      final baseBody = jsonEncode([
        {'insert': 'one\ntwo\n'},
      ]);
      a.createNote(title: 'base', body: baseBody, id: id);
      final engineA = CloudSyncEngine(a, server);
      final engineB = CloudSyncEngine(b, server);
      await engineA.sync();
      await engineB.sync();
      final baseA = a.getNote(id)!;
      final baseB = b.getNote(id)!;
      a.saveContent(
        id,
        title: 'base',
        body: jsonEncode([
          {'insert': 'A\ntwo\n'},
        ]),
        base: baseA.contentVv,
      );
      b.saveContent(
        id,
        title: 'base',
        body: jsonEncode([
          {'insert': 'one\nB\n'},
        ]),
        base: baseB.contentVv,
      );
      await engineA.sync();
      final remoteHlc = a.getRecord(id)!.contentHlc;
      final localHlc = b.getRecord(id)!.contentHlc;

      await engineB.sync();

      final merged = b.getRecord(id)!;
      expect(merged.body, contains('A'));
      expect(merged.body, contains('B'));
      expect(merged.contentHlc.compareTo(remoteHlc), greaterThan(0));
      expect(merged.contentHlc.compareTo(localHlc), greaterThan(0));
      expect(
        dbB.select('SELECT id FROM notes WHERE conflict_of IS NOT NULL'),
        isEmpty,
      );
    },
  );
}
