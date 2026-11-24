import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/cloud/cloud_api.dart';

import '../../support/fake_cloud_server.dart';

void main() {
  const id1 = '00000000-0000-4000-8000-000000000001';
  const id2 = '00000000-0000-4000-8000-000000000002';

  CloudPushItem item(String id, String title, {int baseRev = 0}) =>
      CloudPushItem('note', id, baseRev, title.padRight(64, '0'), {
        'id': id,
        'title': title,
      });

  test(
    'push uses CAS or digest idempotency and assigns sequence per change',
    () async {
      final server = FakeCloudServer();
      final first = await server.push(server.libraryId, 'batch-a', [
        item(id1, 'a'),
        item(id2, 'b'),
      ]);
      expect(first.map((r) => r.seq), [1, 2]);
      final unchanged = await server.push(server.libraryId, 'retry', [
        item(id1, 'a', baseRev: 0),
      ]);
      expect(unchanged.single.unchanged, isTrue);
      expect(unchanged.single.rev, 1);
      expect(unchanged.single.seq, 1);
      expect(server.seq, 2);

      await expectLater(
        server.push(server.libraryId, 'conflict', [item(id1, 'other')]),
        throwsA(
          isA<CloudApiException>().having(
            (error) => error.currentRows.single['row'],
            'full conflicting row',
            isA<Map>(),
          ),
        ),
      );
      expect(server.records['note:$id1']?.row['title'], 'a');
    },
  );

  test(
    'missing CAS conflict has no row and does not commit any batch row',
    () async {
      final server = FakeCloudServer();
      await expectLater(
        server.push(server.libraryId, 'missing', [
          item(id1, 'stale', baseRev: 4),
          item(id2, 'must roll back'),
        ]),
        throwsA(
          isA<CloudApiException>().having(
            (error) => error.currentRows,
            'missing conflict entry',
            [
              <String, Object?>{'kind': 'note', 'id': id1, 'missing': true},
            ],
          ),
        ),
      );
      expect(server.records, isEmpty);
      expect(server.seq, 0);
    },
  );

  test('changes and manifest honor requested page boundaries', () async {
    final server = FakeCloudServer();
    await server.push(server.libraryId, 'batch', [
      item(id1, 'one'),
      item(id2, 'two'),
    ]);
    final first = await server.changes(server.libraryId, 0, limit: 1);
    expect(first.rows.single.seq, 1);
    expect(first.more, isTrue);
    expect(first.next, 1);
    final second = await server.changes(server.libraryId, first.next, limit: 1);
    expect(second.rows.single.seq, 2);
    expect(second.more, isFalse);
    final manifest = await server.manifest(limit: 1);
    expect(manifest.items, hasLength(1));
    expect(manifest.more, isTrue);
    expect(
      manifest.next,
      '${manifest.items.single.kind}:${manifest.items.single.id}',
    );
    final nextManifest = await server.manifest(after: manifest.next);
    expect(nextManifest.items, hasLength(1));
    expect(nextManifest.more, isFalse);
  });

  test(
    'blob append resumes at stored length and verifies completion hash',
    () async {
      final server = FakeCloudServer();
      final bytes = Uint8List.fromList(List<int>.generate(20, (i) => i));
      final hash = '8b' * 32;
      final offset = await server.putBlobChunk(
        hash,
        0,
        bytes.length,
        'image/test',
        bytes.sublist(0, 7),
      );
      expect(offset, 7);
      expect(
        await server.putBlobChunk(hash, 0, bytes.length, 'image/test', bytes),
        7,
      );
      await expectLater(
        server.putBlobChunk(
          hash,
          7,
          bytes.length,
          'image/test',
          bytes.sublist(7),
        ),
        throwsA(isA<CloudApiException>()),
      );
      expect(
        server.partialBlobs,
        isEmpty,
      ); // Hash failure deletes partial bytes.
    },
  );

  test('uploading library rejects non-uploader mutations', () async {
    final server = FakeCloudServer(deviceId: 'joiner')
      ..state = 'uploading'
      ..uploaderDeviceId = 'uploader';
    await expectLater(
      server.push(server.libraryId, 'batch', [item(id1, 'x')]),
      throwsA(
        isA<CloudApiException>().having(
          (e) => e.kind,
          'kind',
          CloudErrorKind.conflict,
        ),
      ),
    );
    await expectLater(
      server.putBlobChunk(
        'aa' * 32,
        0,
        0,
        'application/octet-stream',
        Uint8List(0),
      ),
      throwsA(isA<CloudApiException>()),
    );
  });
}
