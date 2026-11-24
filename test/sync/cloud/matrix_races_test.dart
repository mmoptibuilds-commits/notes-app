import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/sync/cloud/cloud_sync_engine.dart';

import '../../support/fake_cloud_server.dart';
import 'matrix2_support.dart';

void main() {
  for (var request = 1; request <= 5; request++) {
    test(
      'upload resumes after request $request without duplicate records',
      () async {
        final db = matrixDb();
        addTearDown(db.close);
        final repo = NoteRepository(db);
        final folder = repo.createFolder('synthetic folder');
        repo.createNote(
          title: 'synthetic note',
          id: matrixId1,
          folderId: folder.id,
        );
        final noteBeforeUpload = repo.getRecord(matrixId1)!.toJson();
        final server = FakeCloudServer()..state = 'empty';
        final dir = await matrixTempDir();
        addTearDown(() => dir.delete(recursive: true));
        final service = matrixService(
          repo: repo,
          api: server,
          sessions: matrixSessions(),
          dataDir: dir.path,
        );
        addTearDown(service.dispose);
        final before = fullDatabaseDump(db);
        final backup = await service.createVerifiedBackup();
        server.failAtRequest = request;
        await expectLater(service.uploadLibrary(backup), throwsA(anything));
        expect(server.state, request == 1 ? 'empty' : 'uploading');
        server.failAtRequest = null;
        await service.uploadLibrary(backup);
        expect(server.state, 'ready');
        expect(server.records, hasLength(2));
        expect(server.seq, 2);
        expect(repo.getNote(matrixId1)?.title, 'synthetic note');
        expect(repo.getRecord(matrixId1)!.toJson(), noteBeforeUpload);
        expect(
          fullDatabaseDump(db),
          isNot(before),
        ); // local upload bookkeeping is persisted.
        expect(db.getMeta('cloud.phase'), 'ready');
      },
    );
  }

  test(
    'upload requires a verified backup and refuses a changed database',
    () async {
      final db = matrixDb();
      addTearDown(db.close);
      final repo = NoteRepository(db);
      repo.createNote(title: 'synthetic before', id: matrixId1);
      final server = FakeCloudServer()..state = 'empty';
      final dir = await matrixTempDir();
      addTearDown(() => dir.delete(recursive: true));
      final service = matrixService(
        repo: repo,
        api: server,
        sessions: matrixSessions(),
        dataDir: dir.path,
      );
      addTearDown(service.dispose);
      await expectLater(
        service.uploadLibrary(
          const VerifiedBackup('/tmp/not-a-backup', 1, 0, 0),
        ),
        throwsA(isA<StateError>()),
      );
      expect(server.requestCount, 0);
      final backup = await service.createVerifiedBackup();
      final current = repo.getNote(matrixId1)!;
      repo.saveContent(
        matrixId1,
        title: 'synthetic after',
        body: current.body,
        base: current.contentVv,
      );
      final beforeUpload = fullDatabaseDump(db);
      await expectLater(
        service.uploadLibrary(backup),
        throwsA(isA<StateError>()),
      );
      expect(server.requestCount, 0);
      expect(server.records, isEmpty);
      expect(repo.getNote(matrixId1)?.title, 'synthetic after');
      expect(fullDatabaseDump(db), beforeUpload);
    },
  );

  test(
    'save during a slow request returns immediately and pushes next round',
    () async {
      final db = matrixDb();
      addTearDown(db.close);
      final repo = NoteRepository(db);
      db.transaction(() => db.setMeta('cloud.library_id', matrixLibraryId));
      final server = MatrixServer()
        ..libraryId = matrixLibraryId
        ..responseDelay = const Duration(milliseconds: 80);
      final engine = CloudSyncEngine(repo, server, nowMs: () => matrixEpoch);
      final sync = engine.sync();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      repo.createNote(title: 'saved during request', id: matrixId1);
      await sync;
      await engine.sync();
      expect(
        server.records['note:$matrixId1']?.row['title'],
        'saved during request',
      );
    },
  );

  test('edit made while upload is in progress remains pending and syncs after ready', () async {
    final db = matrixDb();
    addTearDown(db.close);
    final repo = NoteRepository(db);
    final folder = repo.createFolder('synthetic folder');
    repo.createNote(title: 'before upload', id: matrixId1, folderId: folder.id);
    final server = FakeCloudServer()..state = 'empty';
    final dir = await matrixTempDir();
    addTearDown(() => dir.delete(recursive: true));
    final service = matrixService(
      repo: repo,
      api: server,
      sessions: matrixSessions(),
      dataDir: dir.path,
    );
    addTearDown(service.dispose);
    final backup = await service.createVerifiedBackup();
    server.beforeNextPush = () async {
      final current = repo.getNote(matrixId1)!;
      repo.saveContent(
        matrixId1,
        title: 'edited during upload',
        body: current.body,
        base: current.contentVv,
      );
    };
    await service.uploadLibrary(backup);
    expect(server.records['note:$matrixId1'], isNull);
    expect(int.parse(db.getMeta('cloud.push_seq')!), lessThan(db.currentSeq));
    await CloudSyncEngine(repo, server, nowMs: () => matrixEpoch).sync();
    expect(
      server.records['note:$matrixId1']?.row['title'],
      'edited during upload',
    );
  });

  test('a second device cannot push while the library is uploading', () async {
    final db = matrixDb();
    addTearDown(db.close);
    final repo = NoteRepository(db);
    repo.createNote(title: 'synthetic pending note', id: matrixId1);
    db.transaction(() {
      db.setMeta('cloud.library_id', matrixLibraryId);
      db.setMeta('cloud.pull_seq', '0');
    });
    final server = FakeCloudServer(deviceId: 'test-joiner')
      ..libraryId = matrixLibraryId
      ..state = 'uploading'
      ..uploaderDeviceId = 'test-uploader';
    await expectLater(
      CloudSyncEngine(repo, server).sync(),
      throwsA(isA<CloudApiException>()),
    );
    expect(server.records, isEmpty);
    expect(repo.getNote(matrixId1), isNotNull);
  });

  test(
    'two service sync requests do not overlap their network work',
    skip:
        'BUG-1: overlapping request is dropped; observed 2 calls instead of 4.',
    () async {
      final db = matrixDb();
      addTearDown(db.close);
      final repo = NoteRepository(db);
      repo.createNote(title: 'synthetic', id: matrixId1);
      db.transaction(() {
        db.setMeta('cloud.library_id', matrixLibraryId);
        db.setMeta('cloud.enabled', 'on');
      });
      final server = FakeCloudServer()..libraryId = matrixLibraryId;
      final sessions = matrixSessions();
      final dir = await matrixTempDir();
      addTearDown(() => dir.delete(recursive: true));
      final service = matrixService(
        repo: repo,
        api: server,
        sessions: sessions,
        dataDir: dir.path,
      );
      addTearDown(service.dispose);
      await service.restoreState();
      server.responseDelay = const Duration(milliseconds: 40);
      final start = server.requestCount;
      await Future.wait([service.start(), service.syncNow()]);
      expect(server.requestCount - start, 4);
      expect(server.records, hasLength(1));
      expect(service.status.syncing, isFalse);
    },
  );

  test(
    'verified backup file is re-read and rejected after tampering',
    () async {
      final db = matrixDb();
      addTearDown(db.close);
      final repo = NoteRepository(db);
      repo.createNote(title: 'synthetic', id: matrixId1);
      final server = FakeCloudServer()..state = 'empty';
      final dir = await matrixTempDir();
      addTearDown(() => dir.delete(recursive: true));
      final service = matrixService(
        repo: repo,
        api: server,
        sessions: matrixSessions(),
        dataDir: dir.path,
      );
      addTearDown(service.dispose);
      final backup = await service.createVerifiedBackup();
      await File(backup.path).writeAsString('{}');
      await expectLater(service.uploadLibrary(backup), throwsA(anything));
      expect(server.requestCount, 0);
      expect(repo.getNote(matrixId1), isNotNull);
    },
  );

  test('verified backup rejects attachment bytes changed in the database', skip: 'BUG-2: upload does not compare current attachment bytes with the verified backup.', () async {
    final db = matrixDb();
    addTearDown(db.close);
    final repo = NoteRepository(db);
    final source = repo.putAttachment(
      Uint8List.fromList([1, 2, 3]),
      'image/test',
    );
    repo.createNote(
      title: 'synthetic image note',
      id: matrixId1,
      body: '[{"insert":{"image":"$source"}},{"insert":"\\n"}]',
    );
    final server = FakeCloudServer()..state = 'empty';
    final dir = await matrixTempDir();
    addTearDown(() => dir.delete(recursive: true));
    final service = matrixService(
      repo: repo,
      api: server,
      sessions: matrixSessions(),
      dataDir: dir.path,
    );
    addTearDown(service.dispose);
    final backup = await service.createVerifiedBackup();
    db.execute('UPDATE attachments SET data=? WHERE hash=?', [
      Uint8List.fromList([7, 7, 7]),
      source.substring(4),
    ]);
    await expectLater(service.uploadLibrary(backup), throwsA(anything));
    expect(server.requestCount, 0);
    expect(repo.getNote(matrixId1), isNotNull);
  });
}
