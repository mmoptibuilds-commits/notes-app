import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_cloud_server.dart';
import 'matrix_support.dart';

const _ids = [
  '10000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000003',
  '10000000-0000-4000-8000-000000000004',
  '10000000-0000-4000-8000-000000000005',
];

void main() {
  test(
    'two and three devices converge lifecycle and bidirectional edits',
    () async {
      final server = FakeCloudServer();
      final devices = [for (var i = 0; i < 3; i++) matrixDevice(server)];
      addTearDown(() {
        for (final d in devices) {
          d.close();
        }
      });
      final a = devices[0].repo;
      final folder = a.createFolder('Projects');
      for (var i = 0; i < _ids.length; i++) {
        a.createNote(
          id: _ids[i],
          title: 'note $i',
          body: jsonEncode([
            {'insert': 'first $i\nsecond $i\n'},
          ]),
          folderId: folder.id,
        );
      }
      a.createNote(id: '10000000-0000-4000-8000-000000000006');
      await devices[0].engine(server).sync();
      await devices[1].engine(server).sync();
      await devices[2].engine(server).sync();
      expect(syncedDump(devices[0]), syncedDump(devices[1]));

      devices[1].repo.saveContent(
        _ids[0],
        title: 'edited B',
        body: jsonEncode([
          {'insert': 'B first\nsecond 0\n'},
        ]),
        base: devices[1].repo.getNote(_ids[0])!.contentVv,
      );
      devices[2].repo.setPinned([_ids[1]], true);
      devices[0].repo.setArchived([_ids[2]], true);
      devices[0].repo.trash([_ids[3]]);
      devices[0].repo.renameFolder(folder.id, 'Renamed');
      await devices[2].engine(server).sync();
      await devices[0].engine(server).sync();
      await devices[1].engine(server).sync();
      await converge(devices, server);
      expectConverged(devices);
      expect(devices[0].repo.getNote(_ids[0])!.title, 'edited B');
      expect(devices[0].repo.getNote(_ids[1])!.pinned, isTrue);
      expect(devices[0].repo.getNote(_ids[2])!.archived, isTrue);
      expect(devices[0].repo.getNote(_ids[3])!.trashedAt, isNotNull);
      expect(devices[0].repo.listFolders().single.name, 'Renamed');

      devices[1].repo.restore([_ids[3]]);
      devices[1].repo.setArchived([_ids[2]], false);
      devices[1].repo.deleteFolder(folder.id);
      devices[2].repo.purge([_ids[4]]);
      await converge(devices, server);
      expectConverged(devices);
      expect(devices[0].repo.getRecord(_ids[4])!.purged, isTrue);
      expect(devices[0].repo.listFolders(), isEmpty);
      expect(devices[0].repo.getRecord(_ids[3])!.trashedAt, isNull);
    },
  );

  test(
    'offline line edits merge; same-line edits preserve one conflict copy',
    () async {
      final server = FakeCloudServer();
      final devices = [matrixDevice(server), matrixDevice(server)];
      addTearDown(() {
        for (final d in devices) {
          d.close();
        }
      });
      const id = '20000000-0000-4000-8000-000000000001';
      const body = '[{"insert":"one\\ntwo\\nthree\\n"}]';
      devices[0].repo.createNote(id: id, title: 'base', body: body);
      await devices[0].engine(server).sync();
      await devices[1].engine(server).sync();
      for (var round = 0; round < 2; round++) {
        final a = devices[0].repo.getNote(id)!;
        final b = devices[1].repo.getNote(id)!;
        devices[0].repo.saveContent(
          id,
          title: 'A title',
          body: round == 0
              ? '[{"insert":"ONE\\ntwo\\nthree\\n"}]'
              : '[{"insert":"SAME-A\\ntwo\\nthree\\n"}]',
          base: a.contentVv,
        );
        devices[1].repo.saveContent(
          id,
          title: round == 0 ? 'base' : 'B title',
          body: round == 0
              ? '[{"insert":"one\\ntwo\\nTHREE\\n"}]'
              : '[{"insert":"SAME-B\\ntwo\\nthree\\n"}]',
          base: b.contentVv,
        );
        await devices[0].engine(server).sync();
        await devices[1].engine(server).sync();
        await converge(devices, server);
        expectConverged(devices);
        if (round == 0) {
          expect(devices[0].repo.getNote(id)!.body, contains('ONE'));
          expect(devices[0].repo.getNote(id)!.body, contains('THREE'));
          expect(
            devices[0].db.select('SELECT id FROM notes WHERE conflict_of=?', [
              id,
            ]),
            isEmpty,
          );
          expect(devices[0].repo.getNote(id)!.title, 'A title');
        } else {
          expect(
            devices[0].db.select(
              'SELECT id FROM notes WHERE conflict_of=? AND purged=0',
              [id],
            ),
            hasLength(1),
          );
          expect(
            devices[0].repo.getNote(id)!.title,
            isIn(['A title', 'B title']),
          );
        }
      }
    },
  );

  test(
    'note keeps a folder reference until that folder arrives later',
    () async {
      final server = FakeCloudServer();
      final devices = [
        matrixDevice(server),
        matrixDevice(server),
        matrixDevice(server),
      ];
      addTearDown(() {
        for (final d in devices) {
          d.close();
        }
      });
      final folder = devices[0].repo.createFolder('Arrives later');
      const noteId = '25000000-0000-4000-8000-000000000001';
      devices[1].repo.createNote(
        id: noteId,
        title: 'early reference',
        folderId: folder.id,
      );
      await devices[1].engine(server).sync();
      await devices[2].engine(server).sync();
      expect(devices[2].repo.getRecord(noteId)!.folderId, folder.id);
      expect(devices[2].repo.getFolderRecord(folder.id), isNull);
      await devices[0].engine(server).sync();
      await devices[1].engine(server).sync();
      await devices[2].engine(server).sync();
      expect(devices[2].repo.getFolderRecord(folder.id)?.name, 'Arrives later');
      expectConverged(devices);
    },
  );

  test('randomized three-device convergence under edits, delivery orders and faults', () async {
    const seed = 0x51A7;
    final random = Random(seed);
    final server = FakeCloudServer();
    final devices = [for (var i = 0; i < 3; i++) matrixDevice(server)];
    addTearDown(() {
      for (final d in devices) {
        d.close();
      }
    });
    for (var i = 0; i < 8; i++) {
      devices[0].repo.createNote(
        id: '30000000-0000-4000-8000-${(i + 1).toString().padLeft(12, '0')}',
        title: 'seed $i',
        body: jsonEncode([
          {'insert': 'line a $i\nline b $i\n'},
        ]),
      );
    }
    await devices[0].engine(server).sync();
    await devices[1].engine(server).sync();
    await devices[2].engine(server).sync();
    final events = <String>[];
    final noteIds = devices[0].db
        .select('SELECT id FROM notes')
        .map((r) => r['id'] as String)
        .toList();
    for (var i = 0; i < 300; i++) {
      final d = devices[random.nextInt(3)];
      final id = noteIds[random.nextInt(noteIds.length)];
      final n = d.repo.getNote(id);
      if (n == null) continue;
      switch (random.nextInt(10)) {
        case 0:
          final isFirst = random.nextBool();
          d.repo.saveContent(
            id,
            title: n.title,
            body: jsonEncode([
              {'insert': '${isFirst ? 'edit $i' : 'line a'}\nline b $id\n'},
            ]),
            base: n.contentVv,
          );
          events.add('edit:$id:$i');
        case 1:
          d.repo.saveContent(
            id,
            title: 'title-$i',
            body: n.body,
            base: n.contentVv,
          );
          events.add('title:$id:$i');
        case 2:
          d.repo.setPinned([id], !n.pinned);
          events.add('pin:$id');
        case 3:
          d.repo.setArchived([id], !n.archived);
          events.add('archive:$id');
        case 4:
          if (n.trashedAt == null) {
            d.repo.trash([id]);
            events.add('trash:$id');
          } else {
            d.repo.restore([id]);
            events.add('restore:$id');
          }
        case 5:
          final name = 'folder-${random.nextInt(4)}';
          final f = d.repo.createFolder(name);
          d.repo.moveToFolder([id], f.id);
          events.add('folder:$id:$name');
        case 6:
          final fs = d.repo.listFolders();
          if (fs.isNotEmpty) {
            d.repo.renameFolder(fs[random.nextInt(fs.length)].id, 'renamed-$i');
            events.add('rename:$i');
          }
        case 7:
          if (i % 37 == 0 && !d.repo.getRecord(id)!.purged) {
            d.repo.purge([id]);
            events.add('purge:$id');
          }
        case 8:
          final createdId =
              '31000000-0000-4000-8000-${(i + 1).toString().padLeft(12, '0')}';
          d.repo.createNote(id: createdId, title: 'new-$i');
          noteIds.add(createdId);
          events.add('create:$createdId');
        case 9:
          final folders = d.repo.listFolders();
          if (folders.isNotEmpty) {
            final selected = folders[random.nextInt(folders.length)];
            d.repo.deleteFolder(selected.id);
            events.add('delete-folder:${selected.id}');
          }
      }
      final order = [0, 1, 2]..shuffle(random);
      for (final index in order.take(random.nextInt(3) + 1)) {
        final fault = FaultCloudApi(server);
        if (random.nextInt(19) == 0) fault.dropAfterNextPush = true;
        if (random.nextInt(23) == 0) fault.failAt = 1;
        try {
          await devices[index].engine(server, api: fault).sync();
        } on Object {
          events.add('fault:${fault.events.join(',')}');
        }
      }
    }
    try {
      await converge(devices, server, maxRounds: 12);
      expectConverged(devices);
      final conflicts = devices[0].db
          .select(
            'SELECT id FROM notes WHERE conflict_of IS NOT NULL AND purged=0',
          )
          .length;
      expect(conflicts, lessThanOrEqualTo(8 + 300));
    } on Object catch (error) {
      fail(
        'seed=$seed; recent=${events.skip((events.length - 20).clamp(0, events.length)).toList()}; error=$error',
      );
    }
  });
}
