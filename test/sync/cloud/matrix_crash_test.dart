import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/sync/cloud/cloud_api.dart';

import '../../support/fake_cloud_server.dart';
import 'matrix_support.dart';

void main() {
  test('sync resumes after each API request boundary fault and lost response', () async {
    final probe = FakeCloudServer();
    final source = matrixDevice(probe);
    source.repo.createFolder('Crash folder');
    final crashBytes = Uint8List.fromList(
      List<int>.generate(120000, (i) => i & 255),
    );
    final crashImage = source.repo.putAttachment(crashBytes, 'image/crash');
    final imageNote = source.repo.createNote(
      id: '50000000-0000-4000-8000-000000000009',
      title: 'crash image',
    );
    source.repo.saveContent(
      imageNote.id,
      title: imageNote.title,
      body: jsonEncode([
        {
          'insert': {'image': crashImage},
        },
        {'insert': '\n'},
      ]),
      base: imageNote.contentVv,
    );
    for (var i = 0; i < 4; i++) {
      source.repo.createNote(
        id: '50000000-0000-4000-8000-${(i + 1).toString().padLeft(12, '0')}',
        title: 'crash $i',
      );
    }
    await source.engine(probe).sync();
    final requestCount = probe.requestCount;
    source.close();

    for (var fail = 1; fail <= requestCount; fail++) {
      final server = FakeCloudServer();
      final a = matrixDevice(server);
      final b = matrixDevice(server);
      addTearDown(a.close);
      addTearDown(b.close);
      a.repo.createFolder('Crash folder');
      final crashBytes = Uint8List.fromList(
        List<int>.generate(120000, (i) => i & 255),
      );
      final crashImage = a.repo.putAttachment(crashBytes, 'image/crash');
      final imageNote = a.repo.createNote(
        id: '50000000-0000-4000-8000-000000000009',
        title: 'crash image',
      );
      a.repo.saveContent(
        imageNote.id,
        title: imageNote.title,
        body: jsonEncode([
          {
            'insert': {'image': crashImage},
          },
          {'insert': '\n'},
        ]),
        base: imageNote.contentVv,
      );
      for (var i = 0; i < 4; i++) {
        a.repo.createNote(
          id: '50000000-0000-4000-8000-${(i + 1).toString().padLeft(12, '0')}',
          title: 'crash $i',
        );
      }
      final api = FaultCloudApi(server)..failAt = fail;
      try {
        await a.engine(server, api: api).sync();
      } on CloudApiException {
        /* Simulated process stop; restart below. */
      }
      await converge([a, b], server);
      expectConverged([a, b]);
      expect(server.records.length, 6);
    }

    final server = FakeCloudServer();
    final d = matrixDevice(server);
    addTearDown(d.close);
    d.repo.createNote(
      id: '50000000-0000-4000-8000-000000000010',
      title: 'lost both',
    );
    final lost = FaultCloudApi(server)..dropAfterNextPush = true;
    try {
      await d.engine(server, api: lost).sync();
    } on CloudApiException {
      /* Simulated process stop; restart below. */
    }
    await d.engine(server).sync();
    expect(server.records, hasLength(1));
    expect(server.records.values.single.rev, 1);
  });

  test('duplicate push replay is unchanged and a lost pull response replays safely', () async {
    final server = FakeCloudServer();
    final a = matrixDevice(server);
    final b = matrixDevice(server);
    addTearDown(a.close);
    addTearDown(b.close);
    a.repo.createNote(
      id: '50000000-0000-4000-8000-000000000020',
      title: 'duplicate',
    );
    final duplicate = FaultCloudApi(server)..duplicateNextPush = true;
    await a.engine(server, api: duplicate).sync();
    expect(server.records.values.single.rev, 1);
    final pull = FaultCloudApi(server)..dropAfterNextPull = true;
    try {
      await b.engine(server, api: pull).sync();
    } on CloudApiException {
      /* Simulated process stop; restart below. */
    }
    expect(b.repo.getNote('50000000-0000-4000-8000-000000000020'), isNull);
    await b.engine(server).sync();
    expectConverged([a, b]);
  });

  test('upload resumes after interrupted blob/row calls and join remains retryable', () async {
    final temp = await Directory.systemTemp.createTemp('notes-cloud-matrix-');
    addTearDown(() => temp.delete(recursive: true));
    final server = FakeCloudServer()..state = 'empty';
    final d = MatrixDevice(AppDatabase.open(null));
    addTearDown(d.close);
    d.repo.createNote(
      id: '50000000-0000-4000-8000-000000000030',
      title: 'upload',
    );
    final session = MemoryCloudSessionStore()
      ..session = const CloudSession(
        deviceId: 'test-device',
        access: 'fake',
        accessExp: 0,
        refresh: 'fake',
      );
    CloudService service(FaultCloudApi api) => CloudService(
      repo: d.repo,
      api: api,
      sessions: session,
      dataDir: temp.path,
      deviceName: 'test',
      loginLauncher: null,
      unavailable: false,
    );
    final api = FaultCloudApi(server)..failAt = 3;
    final first = service(api);
    final backup = await first.createVerifiedBackup();
    try {
      await first.uploadLibrary(backup);
    } on CloudApiException {
      /* Simulated process stop; restart below. */
    }
    first.dispose();
    final resumed = service(FaultCloudApi(server));
    final nextBackup = await resumed.createVerifiedBackup();
    await resumed.uploadLibrary(nextBackup);
    expect(server.state, 'ready');
    expect(server.records, hasLength(1));
    resumed.dispose();
  });

  test('join restarts after linking but before its first pull page', () async {
    final temp = await Directory.systemTemp.createTemp('notes-cloud-join-');
    addTearDown(() => temp.delete(recursive: true));
    final server = FakeCloudServer();
    final source = matrixDevice(server);
    addTearDown(source.close);
    source.repo.createNote(
      id: '50000000-0000-4000-8000-000000000040',
      title: 'join target',
    );
    await source.engine(server).sync();

    final target = MatrixDevice(AppDatabase.open(null));
    addTearDown(target.close);
    CloudService service(FaultCloudApi api) => CloudService(
      repo: target.repo,
      api: api,
      sessions: MemoryCloudSessionStore(),
      dataDir: temp.path,
      deviceName: 'test',
      loginLauncher: null,
      unavailable: false,
    );
    final interruptedApi = FaultCloudApi(server)..failAt = 9;
    final first = service(interruptedApi);
    final report = await first.inspectForJoin();
    try {
      await first.join(report);
      fail('Expected injected interruption during the join pull.');
    } on CloudApiException {
      // The local library link was committed before the pull request failed.
    }
    expect(target.db.getMeta('cloud.library_id'), server.libraryId);
    first.dispose();

    final restarted = service(FaultCloudApi(server));
    await restarted.engine.sync();
    expectConverged([source, target]);
    expect(
      target.repo.getNote('50000000-0000-4000-8000-000000000040')?.title,
      'join target',
    );
    restarted.dispose();
  });

  test(
    'simultaneous stale pushes resolve by conflict pull and converge',
    () async {
      final server = FakeCloudServer();
      final ds = [matrixDevice(server), matrixDevice(server)];
      addTearDown(() {
        for (final d in ds) {
          d.close();
        }
      });
      const id = '50000000-0000-4000-8000-000000000050';
      ds[0].repo.createNote(id: id, title: 'base');
      await ds[0].engine(server).sync();
      await ds[1].engine(server).sync();
      for (var i = 0; i < 2; i++) {
        final n = ds[i].repo.getNote(id)!;
        ds[i].repo.saveContent(
          id,
          title: 'edited $i',
          body: n.body,
          base: n.contentVv,
        );
      }
      await Future.wait([
        ds[0].engine(server).sync(),
        ds[1].engine(server).sync(),
      ]);
      await converge(ds, server);
      expectConverged(ds);
      expect(
        ds[0].db.select(
          'SELECT id FROM notes WHERE conflict_of=? AND purged=0',
          [id],
        ),
        hasLength(1),
      );
    },
  );
}
