import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/cloud/cloud_sync_engine.dart';
import 'package:notes/sync/cloud/record_digest.dart';

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
}
