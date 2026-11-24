import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_cloud_server.dart';
import 'matrix_support.dart';

void main() {
  test('title merge handles one-side, equal concurrent, and differing concurrent edits', () async {
    final server = FakeCloudServer();
    final ds = [matrixDevice(server), matrixDevice(server)];
    addTearDown(() {
      for (final d in ds) {
        d.close();
      }
    });
    const id = '40000000-0000-4000-8000-000000000001';
    ds[0].repo.createNote(
      id: id,
      title: 'base',
      body: '[{"insert":"a\\nb\\n"}]',
    );
    await ds[0].engine(server).sync();
    await ds[1].engine(server).sync();

    var a = ds[0].repo.getNote(id)!;
    var b = ds[1].repo.getNote(id)!;
    ds[0].repo.saveContent(
      id,
      title: 'A only',
      body: a.body,
      base: a.contentVv,
    );
    ds[1].repo.saveContent(
      id,
      title: 'base',
      body: '[{"insert":"a\\nB\\n"}]',
      base: b.contentVv,
    );
    await ds[0].engine(server).sync();
    await ds[1].engine(server).sync();
    await converge(ds, server);
    expect(ds[0].repo.getNote(id)!.title, 'A only');
    expect(ds[0].repo.getNote(id)!.body, contains('B'));
    expect(
      ds[0].db.select('SELECT id FROM notes WHERE conflict_of=?', [id]),
      isEmpty,
    );

    a = ds[0].repo.getNote(id)!;
    b = ds[1].repo.getNote(id)!;
    ds[0].repo.saveContent(id, title: 'same', body: a.body, base: a.contentVv);
    ds[1].repo.saveContent(id, title: 'same', body: b.body, base: b.contentVv);
    await ds[0].engine(server).sync();
    await ds[1].engine(server).sync();
    await converge(ds, server);
    expect(ds[0].repo.getNote(id)!.title, 'same');
    expect(
      ds[0].db.select('SELECT id FROM notes WHERE conflict_of=?', [id]),
      isEmpty,
    );

    a = ds[0].repo.getNote(id)!;
    b = ds[1].repo.getNote(id)!;
    ds[0].repo.saveContent(
      id,
      title: 'different A',
      body: a.body,
      base: a.contentVv,
    );
    ds[1].repo.saveContent(
      id,
      title: 'different B',
      body: b.body,
      base: b.contentVv,
    );
    await ds[0].engine(server).sync();
    await ds[1].engine(server).sync();
    await converge(ds, server);
    expect(
      ds[0].db.select('SELECT id FROM notes WHERE conflict_of=? AND purged=0', [
        id,
      ]),
      hasLength(1),
    );
    expectConverged(ds);
  });

  test(
    'trash/edit and pin/move concurrent with content merge preserve registers',
    () async {
      final server = FakeCloudServer();
      final ds = [matrixDevice(server), matrixDevice(server)];
      addTearDown(() {
        for (final d in ds) {
          d.close();
        }
      });
      const id = '40000000-0000-4000-8000-000000000002';
      const body = '[{"insert":"first\\nsecond\\n"}]';
      ds[0].repo.createNote(id: id, title: 'base', body: body);
      final folder = ds[0].repo.createFolder('Filed');
      await ds[0].engine(server).sync();
      await ds[1].engine(server).sync();

      final baseA = ds[0].repo.getNote(id)!;
      final baseB = ds[1].repo.getNote(id)!;
      ds[0].repo.trash([id]);
      ds[1].repo.saveContent(
        id,
        title: 'edited elsewhere',
        body: '[{"insert":"first\\nchanged\\n"}]',
        base: baseB.contentVv,
      );
      ds[0].repo.moveToFolder([id], folder.id);
      ds[1].repo.setPinned([id], true);
      await ds[1].engine(server).sync();
      await ds[0].engine(server).sync();
      await converge(ds, server);
      expect(ds[0].repo.getNote(id)!.title, 'edited elsewhere');
      expect(
        ds[0].repo.getNote(id)!.trashedAt,
        isNull,
        reason: 'newer edit restores the note per repository normalization',
      );
      expect(ds[0].repo.getNote(id)!.pinned, isTrue);
      expect(ds[0].repo.getNote(id)!.folderId, folder.id);
      expectConverged(ds);
      expect(baseA.contentVv, baseB.contentVv);
    },
  );

  test('concurrent edit beats delete-forever and converges with tombstone preservation', () async {
    final server = FakeCloudServer();
    final ds = [matrixDevice(server), matrixDevice(server)];
    addTearDown(() {
      for (final d in ds) {
        d.close();
      }
    });
    const id = '40000000-0000-4000-8000-000000000003';
    ds[0].repo.createNote(
      id: id,
      title: 'base',
      body: jsonEncode([
        {'insert': 'line\n'},
      ]),
    );
    await ds[0].engine(server).sync();
    await ds[1].engine(server).sync();
    final a = ds[0].repo.getNote(id)!;
    final b = ds[1].repo.getNote(id)!;
    ds[0].repo.purge([id]);
    ds[1].repo.saveContent(
      id,
      title: 'edited',
      body: '[{"insert":"changed\\n"}]',
      base: b.contentVv,
    );
    await ds[0].engine(server).sync();
    await ds[1].engine(server).sync();
    await converge(ds, server);
    expect(ds[0].repo.getRecord(id)!.purged, isFalse);
    expect(ds[0].repo.getRecord(id)!.title, 'edited');
    expectConverged(ds);
    expect(a.contentVv, b.contentVv);
  });
}
