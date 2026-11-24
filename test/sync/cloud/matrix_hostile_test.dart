import 'package:flutter_test/flutter_test.dart';

import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_sync_engine.dart';
import 'package:notes/sync/cloud/record_digest.dart';

import 'matrix2_support.dart';

void main() {
  test('HTTP timeout is bounded and a later healthy response works', skip: 'BUG-4: request timeout escapes HttpCloudApi as a raw TimeoutException.', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) {
      requests++;
      if (requests == 1) return; // Deliberately leave the first response open.
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true, 'v': 1, 'env': 'test'}));
      request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final api = HttpCloudApi(
      baseUrl: Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
      sessions: MemoryCloudSessionStore(),
      timeout: const Duration(milliseconds: 30),
    );
    addTearDown(api.close);
    await expectLater(
      api.health(),
      throwsA(
        isA<CloudApiException>().having(
          (e) => e.kind,
          'timeout',
          CloudErrorKind.network,
        ),
      ),
    );
    expect((await api.health())['ok'], isTrue);
    expect(requests, 2);
  });

  test(
    'malformed JSON is sanitized and a later healthy response recovers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var malformed = true;
      server.listen((request) {
        request.response
          ..headers.contentType = ContentType.json
          ..write(malformed ? '{' : '{"ok":true,"v":1,"env":"test"}');
        request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final api = HttpCloudApi(
        baseUrl: Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
        sessions: MemoryCloudSessionStore(),
      );
      addTearDown(api.close);
      await expectLater(
        api.health(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'malformed',
            CloudErrorKind.malformed,
          ),
        ),
      );
      malformed = false;
      expect((await api.health())['ok'], isTrue);
    },
  );

  test(
    'HTML error response is sanitized and later healthy response recovers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var broken = true;
      server.listen((request) {
        if (broken) {
          request.response
            ..statusCode = HttpStatus.serviceUnavailable
            ..headers.contentType = ContentType.html
            ..write('<html>synthetic secret body</html>');
        } else {
          request.response
            ..headers.contentType = ContentType.json
            ..write('{"ok":true,"v":1,"env":"test"}');
        }
        request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final api = HttpCloudApi(
        baseUrl: Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
        sessions: MemoryCloudSessionStore(),
      );
      addTearDown(api.close);
      await expectLater(
        api.health(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'status',
            CloudErrorKind.server,
          ),
        ),
      );
      broken = false;
      expect((await api.health())['ok'], isTrue);
    },
  );

  test('valid JSON with an incorrect response content type is rejected', skip: 'BUG-3: HTTP responses are parsed as JSON without validating Content-Type.', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.html
        ..write('{"ok":true,"v":1,"env":"test"}');
      request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final api = HttpCloudApi(
      baseUrl: Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
      sessions: MemoryCloudSessionStore(),
    );
    addTearDown(api.close);
    await expectLater(
      api.health(),
      throwsA(
        isA<CloudApiException>().having(
          (e) => e.kind,
          'malformed',
          CloudErrorKind.malformed,
        ),
      ),
    );
  });

  for (final hostile in [
    'wrong library id',
    'rewound sequence',
    'duplicate ids',
    'wrong digest',
    'record id differs from row id',
    'giant row',
    'unknown kind',
    'page that never ends',
  ]) {
    test(
      '$hostile response fails safely and a healthy retry recovers',
      () async {
        final db = matrixDb();
        addTearDown(db.close);
        final repo = NoteRepository(db);
        db.transaction(() {
          db.setMeta('cloud.library_id', matrixLibraryId);
          db.setMeta('cloud.pull_seq', '0');
        });
        final server = MatrixServer()..libraryId = matrixLibraryId;
        final seed = matrixDb();
        addTearDown(seed.close);
        final seedRepo = NoteRepository(seed);
        seedRepo.createNote(title: 'remote synthetic title', id: matrixId2);
        final row = seedRepo.getRecord(matrixId2)!.toJson();
        server.records['note:$matrixId2'] = CloudRecord(
          kind: 'note',
          id: matrixId2,
          rev: 1,
          seq: 1,
          digest: recordDigest(row),
          row: row,
        );
        server.seq = 1;
        switch (hostile) {
          case 'wrong library id':
            server.wrongLibraryOnChanges = 'another-library';
          case 'rewound sequence':
            server.rewoundSequence = 0;
          case 'duplicate ids':
            server.duplicateIdsOnNextPage = true;
          case 'wrong digest':
            server.wrongDigestOnNextPage = true;
          case 'record id differs from row id':
            server.wrongRecordIdOnNextPage = true;
          case 'giant row':
            server.giantRowOnNextPage = true;
          case 'unknown kind':
            server.unknownKindOnNextPage = true;
          case 'page that never ends':
            server.endlessPage = true;
        }
        final engine = CloudSyncEngine(repo, server, nowMs: () => matrixEpoch);
        final before = fullDatabaseDump(db);
        Object? failure;
        try {
          await engine.sync();
        } on Object catch (e) {
          failure = e;
        }
        final quarantined =
            hostile == 'wrong digest' ||
            hostile == 'record id differs from row id' ||
            hostile == 'unknown kind';
        if (quarantined) {
          expect(failure, isNull);
          expect(db.getMeta('cloud.pull_seq'), '1');
          expect(
            db.select("SELECT id FROM quarantine WHERE peer_id='cloud'"),
            hasLength(1),
          );
        } else {
          expect(failure, isNotNull);
          expect('$failure', isNot(contains('test-access')));
          expect('$failure', isNot(contains('test-refresh')));
          expect('$failure', isNot(contains('remote synthetic title')));
          expect(db.getMeta('cloud.pull_seq'), '0');
          expect(fullDatabaseDump(db), before);
        }

        server
          ..wrongLibraryOnChanges = null
          ..rewoundSequence = null
          ..endlessPage = false;
        if (quarantined) {
          server.seq = 2;
          server.records['note:$matrixId2'] = CloudRecord(
            kind: 'note',
            id: matrixId2,
            rev: 2,
            seq: 2,
            digest: recordDigest(row),
            row: row,
          );
        }
        await engine.sync();
        expect(repo.getNote(matrixId2)?.title, 'remote synthetic title');
        expect(db.getMeta('cloud.pull_seq'), quarantined ? '2' : '1');
      },
    );
  }

  test(
    'clock skew stops before cursor and clock move, then healthy retry works',
    () async {
      final db = matrixDb();
      final sourceDb = matrixDb();
      addTearDown(db.close);
      addTearDown(sourceDb.close);
      final repo = NoteRepository(db);
      final source = NoteRepository(sourceDb);
      source.createNote(title: 'synthetic', id: matrixId1);
      final row = source.getRecord(matrixId1)!.toJson();
      final server = MatrixServer()
        ..libraryId = matrixLibraryId
        ..seq = 1;
      server.records['note:$matrixId1'] = CloudRecord(
        kind: 'note',
        id: matrixId1,
        rev: 1,
        seq: 1,
        digest: recordDigest(row),
        row: row,
      );
      db.transaction(() {
        db.setMeta('cloud.library_id', matrixLibraryId);
        db.setMeta('cloud.pull_seq', '0');
      });
      final future = matrixEpoch + const Duration(days: 3).inMilliseconds;
      final altered = {
        ...row,
        'contentHlc':
            '${future.toRadixString(16).padLeft(12, '0')}0000-hostile',
      };
      server.records['note:$matrixId1'] = CloudRecord(
        kind: 'note',
        id: matrixId1,
        rev: 1,
        seq: 1,
        digest: recordDigest(altered),
        row: altered,
      );
      final engine = CloudSyncEngine(repo, server, nowMs: () => matrixEpoch);
      final clockBefore = db.clock.last;
      await expectLater(
        engine.sync(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.message,
            'plain error',
            contains("This device's or another device's clock looks wrong"),
          ),
        ),
      );
      expect(db.getMeta('cloud.pull_seq'), '0');
      expect(db.clock.last, clockBefore);
      expect(repo.getRecord(matrixId1), isNull);
      server.records['note:$matrixId1'] = CloudRecord(
        kind: 'note',
        id: matrixId1,
        rev: 1,
        seq: 1,
        digest: recordDigest(row),
        row: row,
      );
      await engine.sync();
      expect(repo.getRecord(matrixId1), isNotNull);
      expect(db.getMeta('cloud.pull_seq'), '1');
    },
  );

  test('missing attachment bytes prevent a note from being pushed', () async {
    final db = matrixDb();
    addTearDown(db.close);
    final repo = NoteRepository(db);
    final source = repo.putAttachment(
      Uint8List.fromList([1, 2, 3]),
      'image/test',
    );
    repo.createNote(
      title: 'synthetic attachment',
      body: '[{"insert":{"image":"$source"}},{"insert":"\\n"}]',
      id: matrixId1,
    );
    final hash = source.substring(4);
    db.execute('UPDATE attachments SET data=NULL WHERE hash=?', [hash]);
    db.transaction(() => db.setMeta('cloud.library_id', matrixLibraryId));
    final server = MatrixServer()..libraryId = matrixLibraryId;
    final engine = CloudSyncEngine(repo, server, nowMs: () => matrixEpoch);
    await engine.sync();
    expect(server.records, isEmpty);
    expect(engine.unavailableBlobs, contains(hash));
    expect(db.getMeta('cloud.push_seq'), '0');
  });

  test(
    'future HLC leaves cursor and local clock unchanged, then recovers',
    () async {
      final db = matrixDb();
      final sourceDb = matrixDb();
      addTearDown(db.close);
      addTearDown(sourceDb.close);
      final repo = NoteRepository(db);
      final source = NoteRepository(sourceDb);
      source.createNote(title: 'synthetic', id: matrixId1);
      final row = source.getRecord(matrixId1)!.toJson();
      final server = MatrixServer()
        ..libraryId = matrixLibraryId
        ..seq = 1;
      db.transaction(() {
        db.setMeta('cloud.library_id', matrixLibraryId);
        db.setMeta('cloud.pull_seq', '0');
      });
      final future = matrixEpoch + const Duration(days: 4).inMilliseconds;
      final futureRow = {
        ...row,
        'contentHlc':
            '${future.toRadixString(16).padLeft(12, '0')}0000-hostile',
      };
      server.records['note:$matrixId1'] = CloudRecord(
        kind: 'note',
        id: matrixId1,
        rev: 1,
        seq: 1,
        digest: recordDigest(futureRow),
        row: futureRow,
      );
      final clockBefore = db.clock.last;
      final engine = CloudSyncEngine(repo, server, nowMs: () => matrixEpoch);
      await expectLater(
        engine.sync(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.message,
            'plain language message',
            contains("This device's or another device's clock looks wrong"),
          ),
        ),
      );
      expect(db.getMeta('cloud.pull_seq'), '0');
      expect(db.clock.last, clockBefore);
      expect(repo.getRecord(matrixId1), isNull);
      server.records['note:$matrixId1'] = CloudRecord(
        kind: 'note',
        id: matrixId1,
        rev: 1,
        seq: 1,
        digest: recordDigest(row),
        row: row,
      );
      await engine.sync();
      expect(repo.getRecord(matrixId1), isNotNull);
      expect(db.getMeta('cloud.pull_seq'), '1');
    },
  );
}
