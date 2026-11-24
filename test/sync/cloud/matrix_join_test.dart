import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_sync_engine.dart';
import 'package:notes/sync/cloud/record_digest.dart';

import '../../support/fake_cloud_server.dart';
import 'matrix2_support.dart';

void main() {
  test('matching copies join and stale reports are re-inspected', () async {
    final sourceDb = matrixDb();
    final peerDb = matrixDb();
    addTearDown(sourceDb.close);
    addTearDown(peerDb.close);
    final source = NoteRepository(sourceDb);
    final peer = NoteRepository(peerDb);
    source.createNote(title: 'synthetic', id: matrixId1);
    final server = FakeCloudServer();
    // A test library is linked explicitly, as production links it after init.
    sourceDb.transaction(
      () => sourceDb.setMeta('cloud.library_id', server.libraryId),
    );
    await CloudSyncEngine(source, server).sync();
    cloneServerRowsTo(server, peer);
    peerDb.transaction(
      () => peerDb.setMeta('cloud.library_id', server.libraryId),
    );
    final dir = await matrixTempDir();
    addTearDown(() => dir.delete(recursive: true));
    final service = matrixService(
      repo: peer,
      api: server,
      sessions: matrixSessions(),
      dataDir: dir.path,
    );
    addTearDown(service.dispose);

    final report = await service.inspectForJoin();
    expect(report.exact, isTrue);
    await service.join(report);
    expect(peerDb.getMeta('cloud.library_id'), server.libraryId);
    expect(report.identical, 1);

    final stale = await service.inspectForJoin();
    peer.createNote(title: 'local addition', id: matrixId2);
    final before = fullDatabaseDump(peerDb);
    await expectLater(service.join(stale), throwsA(isA<StateError>()));
    expect(fullDatabaseDump(peerDb), before);
  });

  test('empty device joins by pulling the ready library', () async {
    final sourceDb = matrixDb();
    final emptyDb = matrixDb();
    addTearDown(sourceDb.close);
    addTearDown(emptyDb.close);
    final source = NoteRepository(sourceDb);
    final empty = NoteRepository(emptyDb);
    source.createNote(title: 'synthetic', id: matrixId1);
    final server = FakeCloudServer();
    sourceDb.transaction(
      () => sourceDb.setMeta('cloud.library_id', server.libraryId),
    );
    await CloudSyncEngine(source, server).sync();
    final service = matrixService(
      repo: empty,
      api: server,
      sessions: matrixSessions(),
      dataDir: (await matrixTempDir()).path,
    );
    addTearDown(service.dispose);
    final result = await service.inspectForJoin();
    expect(result.onlyThere, 1);
    expect(result.exact, isFalse);
    await service.join(result);
    expect(empty.getNote(matrixId1)?.title, 'synthetic');
    expect(emptyDb.getMeta('cloud.pull_seq'), '1');
  });

  test(
    'join mismatch report exposes counts only and leaves both copies intact',
    () async {
      final sourceDb = matrixDb();
      final peerDb = matrixDb();
      addTearDown(sourceDb.close);
      addTearDown(peerDb.close);
      final source = NoteRepository(sourceDb);
      final peer = NoteRepository(peerDb);
      source.createNote(title: 'private synthetic title', id: matrixId1);
      final server = FakeCloudServer();
      sourceDb.transaction(
        () => sourceDb.setMeta('cloud.library_id', server.libraryId),
      );
      await CloudSyncEngine(source, server).sync();
      cloneServerRowsTo(server, peer);
      peerDb.transaction(
        () => peerDb.setMeta('cloud.library_id', server.libraryId),
      );
      final current = peer.getNote(matrixId1)!;
      peer.saveContent(
        matrixId1,
        title: 'different synthetic title',
        body: jsonEncode([
          {'insert': 'different body\n'},
        ]),
        base: current.contentVv,
      );
      final dir = await matrixTempDir();
      addTearDown(() => dir.delete(recursive: true));
      final service = matrixService(
        repo: peer,
        api: server,
        sessions: matrixSessions(),
        dataDir: dir.path,
      );
      addTearDown(service.dispose);
      final report = await service.inspectForJoin();
      expect(report.differing, 1);
      expect(report.exact, isFalse);
      expect(report.toString(), isNot(contains('private synthetic title')));
      final localBefore = fullDatabaseDump(peerDb);
      final serverBefore = server.records.entries
          .map((e) => '${e.key}:${e.value.digest}')
          .toList();
      await expectLater(service.join(report), throwsA(isA<StateError>()));
      expect(fullDatabaseDump(peerDb), localBefore);
      expect(
        server.records.entries
            .map((e) => '${e.key}:${e.value.digest}')
            .toList(),
        serverBefore,
      );
    },
  );

  test('library id mismatch blocks a non-empty join without writes', () async {
    final db = matrixDb();
    addTearDown(db.close);
    final repo = NoteRepository(db);
    repo.createNote(title: 'synthetic', id: matrixId1);
    db.transaction(() => db.setMeta('cloud.library_id', 'different-library'));
    final server = FakeCloudServer()..libraryId = 'another-library';
    final service = matrixService(
      repo: repo,
      api: server,
      sessions: matrixSessions(),
      dataDir: (await matrixTempDir()).path,
    );
    addTearDown(service.dispose);
    final report = await service.inspectForJoin();
    final before = fullDatabaseDump(db);
    await expectLater(service.join(report), throwsA(isA<StateError>()));
    expect(fullDatabaseDump(db), before);
    expect(server.records, isEmpty);
  });

  test('server digest mismatch in manifest is counted as differing', () async {
    final db = matrixDb();
    addTearDown(db.close);
    final repo = NoteRepository(db);
    final note = repo.createNote(title: 'synthetic', id: matrixId1);
    final server = FakeCloudServer();
    final row = repo.getRecord(note.id)!.toJson();
    server.records['note:${note.id}'] = CloudRecord(
      kind: 'note',
      id: note.id,
      rev: 1,
      seq: 1,
      digest: recordDigest(row),
      row: row,
    );
    server.seq = 1;
    final altered = {...row, 'title': 'server-side synthetic'};
    server.records['note:${note.id}'] = CloudRecord(
      kind: 'note',
      id: note.id,
      rev: 1,
      seq: 1,
      digest: recordDigest(altered),
      row: altered,
    );
    final service = matrixService(
      repo: repo,
      api: server,
      sessions: matrixSessions(),
      dataDir: (await matrixTempDir()).path,
    );
    addTearDown(service.dispose);
    expect((await service.inspectForJoin()).differing, 1);
  });

  for (final mismatch in [
    'extra local note',
    'extra server note',
    'different body',
    'different title',
    'different folder reference',
    'folder only local',
    'folder only server',
    'server attachment missing',
    'attachment bytes differ',
    'tombstone differs',
    'pinned differs',
    'archived differs',
    'trashed differs',
  ]) {
    test('$mismatch blocks join without changing either database', () async {
      final sourceDb = matrixDb();
      final peerDb = matrixDb();
      addTearDown(sourceDb.close);
      addTearDown(peerDb.close);
      final source = NoteRepository(sourceDb);
      final peer = NoteRepository(peerDb);
      final folder = source.createFolder('folder marker');
      final bytes = Uint8List.fromList([4, 8, 15, 16, 23, 42]);
      final image = source.putAttachment(bytes, 'image/test');
      source.createNote(
        title: 'title marker',
        body: jsonEncode([
          {
            'insert': {'image': image},
          },
          {'insert': '\n'},
        ]),
        id: matrixId1,
        folderId: folder.id,
      );
      final server = FakeCloudServer();
      sourceDb.transaction(
        () => sourceDb.setMeta('cloud.library_id', server.libraryId),
      );
      await CloudSyncEngine(source, server).sync();
      cloneServerRowsTo(server, peer);
      peerDb.transaction(
        () => peerDb.setMeta('cloud.library_id', server.libraryId),
      );
      final note = peer.getNote(matrixId1)!;
      switch (mismatch) {
        case 'extra local note':
          peer.createNote(title: 'local-only marker', id: matrixId2);
        case 'extra server note':
          source.createNote(title: 'server-only marker', id: matrixId2);
          await CloudSyncEngine(source, server).sync();
        case 'different body':
          peer.saveContent(
            matrixId1,
            title: note.title,
            body: jsonEncode([
              {'insert': 'different body marker\n'},
            ]),
            base: note.contentVv,
          );
        case 'different title':
          peer.saveContent(
            matrixId1,
            title: 'changed title marker',
            body: note.body,
            base: note.contentVv,
          );
        case 'different folder reference':
          peer.moveToFolder([matrixId1], null);
        case 'folder only local':
          peer.createFolder('local-only folder marker');
        case 'folder only server':
          source.createFolder('server-only folder marker');
          await CloudSyncEngine(source, server).sync();
        case 'server attachment missing':
          server.blobs.clear();
          server.blobMimes.clear();
        case 'attachment bytes differ':
          final other = peer.putAttachment(
            Uint8List.fromList([9, 9, 9]),
            'image/test',
          );
          peer.saveContent(
            matrixId1,
            title: note.title,
            body: jsonEncode([
              {
                'insert': {'image': other},
              },
              {'insert': '\n'},
            ]),
            base: note.contentVv,
          );
        case 'tombstone differs':
          peer.purge([matrixId1]);
        case 'pinned differs':
          peer.setPinned([matrixId1], true);
        case 'archived differs':
          peer.setArchived([matrixId1], true);
        case 'trashed differs':
          peer.trash([matrixId1]);
      }
      final dir = await matrixTempDir();
      addTearDown(() => dir.delete(recursive: true));
      final service = matrixService(
        repo: peer,
        api: server,
        sessions: matrixSessions(),
        dataDir: dir.path,
      );
      addTearDown(service.dispose);
      final report = await service.inspectForJoin();
      expect(report.exact, isFalse, reason: mismatch);
      expect(report.toString(), isNot(contains('title marker')));
      expect(report.toString(), isNot(contains('body marker')));
      if (mismatch == 'extra local note' || mismatch == 'folder only local') {
        expect(report.onlyHere, 1);
      } else if (mismatch == 'extra server note' ||
          mismatch == 'folder only server') {
        expect(report.onlyThere, 1);
      } else if (mismatch == 'server attachment missing') {
        expect(report.missingAttachments, 1);
      } else {
        expect(report.differing, greaterThan(0), reason: mismatch);
      }
      final localBefore = fullDatabaseDump(peerDb);
      final remoteBefore = server.records.entries
          .map((e) => '${e.key}:${e.value.digest}:${e.value.seq}')
          .toList();
      final blobsBefore = server.blobs.keys.toList()..sort();
      await expectLater(service.join(report), throwsA(isA<StateError>()));
      expect(fullDatabaseDump(peerDb), localBefore, reason: mismatch);
      expect(
        server.records.entries
            .map((e) => '${e.key}:${e.value.digest}:${e.value.seq}')
            .toList(),
        remoteBefore,
        reason: mismatch,
      );
      expect(server.blobs.keys.toList()..sort(), blobsBefore, reason: mismatch);
    });
  }
}
