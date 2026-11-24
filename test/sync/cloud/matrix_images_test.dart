import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_cloud_server.dart';
import 'matrix_support.dart';

String _imageBody(String source) => jsonEncode([
  {
    'insert': {'image': source},
  },
  {'insert': '\n'},
]);

void main() {
  test(
    'images travel both directions and verify SHA-256 before storing',
    () async {
      final server = FakeCloudServer();
      final a = matrixDevice(server);
      final b = matrixDevice(server);
      addTearDown(a.close);
      addTearDown(b.close);
      final bytesA = Uint8List.fromList(
        List<int>.generate(230_123, (i) => (i * 37) & 255),
      );
      final sourceA = a.repo.putAttachment(bytesA, 'image/test-a');
      final noteA = a.repo.createNote(
        id: '60000000-0000-4000-8000-000000000001',
        title: 'A image',
      );
      a.repo.saveContent(
        noteA.id,
        title: noteA.title,
        body: _imageBody(sourceA),
        base: noteA.contentVv,
      );
      await a.engine(server).sync();
      await b.engine(server).sync();
      expect(b.repo.attachmentBytes(sourceA.substring(4)), bytesA);
      expect(server.blobs[sourceA.substring(4)], bytesA);

      final bytesB = Uint8List.fromList(
        List<int>.generate(180_321, (i) => (i * 19 + 3) & 255),
      );
      final sourceB = b.repo.putAttachment(bytesB, 'image/test-b');
      final noteB = b.repo.createNote(
        id: '60000000-0000-4000-8000-000000000002',
        title: 'B image',
      );
      b.repo.saveContent(
        noteB.id,
        title: noteB.title,
        body: _imageBody(sourceB),
        base: noteB.contentVv,
      );
      await b.engine(server).sync();
      await a.engine(server).sync();
      expect(a.repo.attachmentBytes(sourceB.substring(4)), bytesB);
      expectConverged([a, b]);
    },
  );

  test(
    'partial chunk resumes and corrupt download is rejected then retried',
    () async {
      final server = FakeCloudServer();
      final a = matrixDevice(server);
      final b = matrixDevice(server);
      addTearDown(a.close);
      addTearDown(b.close);
      final bytes = Uint8List.fromList(
        List<int>.generate(260_000, (i) => i & 255),
      );
      final source = a.repo.putAttachment(bytes, 'image/retry');
      final hash = source.substring(4);
      final firstOffset = await server.putBlobChunk(
        hash,
        0,
        bytes.length,
        'image/retry',
        bytes.sublist(0, 91_000),
      );
      expect(firstOffset, 91_000);
      final note = a.repo.createNote(
        id: '60000000-0000-4000-8000-000000000003',
        title: 'resumed',
      );
      a.repo.saveContent(
        note.id,
        title: note.title,
        body: _imageBody(source),
        base: note.contentVv,
      );
      await a.engine(server).sync();
      expect(server.blobs[hash], bytes);

      final corrupt = FaultCloudApi(server)..corruptNextBlob = true;
      try {
        await b.engine(server, api: corrupt).sync();
      } on FormatException {
        /* Hash rejection is expected before retry. */
      }
      expect(b.repo.attachmentBytes(hash), isNull);
      await b.engine(server).sync();
      expect(b.repo.attachmentBytes(hash), bytes);
      expectConverged([a, b]);
    },
  );

  test(
    'a note without local attachment bytes does not block other notes',
    () async {
      final server = FakeCloudServer();
      final d = matrixDevice(server);
      addTearDown(d.close);
      final missingHash = 'ab' * 32;
      final waiting = d.repo.createNote(
        id: '60000000-0000-4000-8000-000000000004',
        title: 'waiting attachment',
      );
      d.repo.saveContent(
        waiting.id,
        title: waiting.title,
        body: _imageBody('att:$missingHash'),
        base: waiting.contentVv,
      );
      d.repo.createNote(
        id: '60000000-0000-4000-8000-000000000006',
        title: 'no image',
      );
      final engine = d.engine(server);
      await engine.sync();
      expect(
        server.records.keys,
        contains('note:60000000-0000-4000-8000-000000000006'),
      );
      expect(
        server.records.keys,
        isNot(contains('note:60000000-0000-4000-8000-000000000004')),
      );
      expect(engine.unavailableBlobs, contains(missingHash));
    },
  );

  test(
    'oversize attachment does not prevent its referencing note from syncing',
    () async {
      final server = FakeCloudServer();
      final d = matrixDevice(server);
      addTearDown(d.close);
      final oversized = Uint8List(20 * 1024 * 1024 + 1);
      final source = d.repo.putAttachment(oversized, 'image/too-large');
      final note = d.repo.createNote(
        id: '60000000-0000-4000-8000-000000000005',
        title: 'over limit',
      );
      d.repo.saveContent(
        note.id,
        title: note.title,
        body: _imageBody(source),
        base: note.contentVv,
      );
      await d.engine(server).sync();
      expect(server.records.keys, contains('note:${note.id}'));
    },
    skip: 'BUG-1: oversized local attachment marks its note unavailable and blocks the push',
  );
}
