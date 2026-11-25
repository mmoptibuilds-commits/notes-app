import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_sync_engine.dart';

import '../../support/fake_cloud_server.dart';

const matrixNow = 1_800_000_000_000;

class MatrixDevice {
  MatrixDevice(this.db) : repo = NoteRepository(db, nowMs: () => matrixNow);
  final AppDatabase db;
  final NoteRepository repo;
  CloudSyncEngine engine(FakeCloudServer server, {CloudApi? api}) =>
      CloudSyncEngine(repo, api ?? server, nowMs: () => matrixNow);
  void link(FakeCloudServer server) =>
      db.transaction(() => db.setMeta('cloud.library_id', server.libraryId));
  void close() => db.close();
}

// One strictly increasing wall clock shared by every device in the test, so two
// devices never stamp a change in the same millisecond. A tie is broken by the
// random device id, which made order-dependent assertions fail now and then.
var _wallTick = DateTime.now().millisecondsSinceEpoch;

MatrixDevice matrixDevice(FakeCloudServer server) {
  final device = MatrixDevice(
    AppDatabase.open(null, wallClock: () => ++_wallTick),
  );
  device.link(server);
  return device;
}

/// A canonical dump of every synced table. Device-local sequence numbers and
/// cloud revision bookkeeping are intentionally excluded.
Map<String, Object?> syncedDump(MatrixDevice device) {
  final notes = device.db.select('SELECT * FROM notes ORDER BY id');
  final folders = device.db.select('SELECT * FROM folders ORDER BY id');
  final attachments = device.db.select(
    'SELECT hash,mime,size,data FROM attachments ORDER BY hash',
  );
  final links = device.db.select(
    'SELECT note_id,hash FROM note_attachments ORDER BY note_id,hash',
  );
  return {
    'notes': [
      for (final row in notes)
        device.repo.getRecord(row['id'] as String)!.toJson(),
    ],
    'folders': [
      for (final row in folders)
        device.repo.getFolderRecord(row['id'] as String)!.toJson(),
    ],
    'attachments': [
      for (final row in attachments)
        {
          'hash': row['hash'],
          'mime': row['mime'],
          'size': row['size'],
          'data': row['data'] == null
              ? null
              : base64Encode(row['data'] as Uint8List),
        },
    ],
    'note_attachments': [
      for (final row in links) {'note_id': row['note_id'], 'hash': row['hash']},
    ],
  };
}

Future<void> syncAll(List<MatrixDevice> devices, FakeCloudServer server) async {
  for (final device in devices) {
    await device.engine(server).sync();
  }
}

Future<void> converge(
  List<MatrixDevice> devices,
  FakeCloudServer server, {
  int maxRounds = 8,
}) async {
  for (var round = 0; round < maxRounds; round++) {
    for (final device in devices) {
      await device.engine(server).sync();
    }
    final expected = jsonEncode(syncedDump(devices.first));
    if (devices.skip(1).every((d) => jsonEncode(syncedDump(d)) == expected)) {
      return;
    }
  }
  fail('Devices did not converge within $maxRounds rounds.');
}

void expectConverged(List<MatrixDevice> devices) {
  final expected = syncedDump(devices.first);
  for (final device in devices.skip(1)) {
    expect(syncedDump(device), expected);
  }
}

/// Injects deterministic request faults while preserving the underlying fake's
/// commit semantics. A selected method can fail before forwarding or after its
/// server side effect, modeling a lost response.
class FaultCloudApi implements CloudApi {
  FaultCloudApi(this.inner);
  final CloudApi inner;
  int calls = 0;
  int? failAt;
  bool dropAfterNextPush = false;
  bool dropAfterNextPull = false;
  bool duplicateNextPush = false;
  bool corruptNextBlob = false;
  final events = <String>[];

  void _before(String method) {
    calls++;
    events.add(method);
    if (calls == failAt) {
      throw const CloudApiException(CloudErrorKind.network, 'Injected fault.');
    }
  }

  @override
  Future<Map<String, Object?>> health() async {
    _before('health');
    return inner.health();
  }

  @override
  Future<Map<String, Object?>> authStart(Uri uri) async {
    _before('authStart');
    return inner.authStart(uri);
  }

  @override
  Future<CloudSession> authToken(String code, String verifier) async {
    _before('authToken');
    return inner.authToken(code, verifier);
  }

  @override
  Future<void> logout() async {
    _before('logout');
    return inner.logout();
  }

  @override
  Future<Map<String, Object?>> devices() async {
    _before('devices');
    return inner.devices();
  }

  @override
  Future<void> revokeDevice(String id) async {
    _before('revokeDevice');
    return inner.revokeDevice(id);
  }

  @override
  Future<Map<String, Object?>> head() async {
    _before('head');
    return inner.head();
  }

  @override
  Future<CloudLibraryInfo> library() async {
    _before('library');
    return inner.library();
  }

  @override
  Future<Map<String, Object?>> initLibrary() async {
    _before('initLibrary');
    return inner.initLibrary();
  }

  @override
  Future<void> markReady(String libraryId) async {
    _before('markReady');
    return inner.markReady(libraryId);
  }

  @override
  Future<CloudChanges> changes(
    String libraryId,
    int since, {
    int limit = 50,
    int maxBytes = 204800,
  }) async {
    _before('changes');
    final result = await inner.changes(
      libraryId,
      since,
      limit: limit,
      maxBytes: maxBytes,
    );
    if (dropAfterNextPull) {
      dropAfterNextPull = false;
      throw const CloudApiException(
        CloudErrorKind.network,
        'Lost pull response.',
      );
    }
    return result;
  }

  @override
  Future<List<CloudPushResult>> push(
    String libraryId,
    String batchId,
    List<CloudPushItem> rows,
  ) async {
    _before('push');
    final result = await inner.push(libraryId, batchId, rows);
    if (duplicateNextPush) {
      duplicateNextPush = false;
      final repeated = await inner.push(libraryId, '$batchId-replay', rows);
      expect(repeated.every((r) => r.unchanged), isTrue);
    }
    if (dropAfterNextPush) {
      dropAfterNextPush = false;
      throw const CloudApiException(
        CloudErrorKind.network,
        'Lost push response.',
      );
    }
    return result;
  }

  @override
  Future<CloudManifestPage> manifest({String? after, int limit = 500}) async {
    _before('manifest');
    return inner.manifest(after: after, limit: limit);
  }

  @override
  Future<({Set<String> missing, Map<String, int> partial})> checkBlobs(
    List<String> hashes,
  ) async {
    _before('checkBlobs');
    return inner.checkBlobs(hashes);
  }

  @override
  Future<int> putBlobChunk(
    String hash,
    int offset,
    int size,
    String mime,
    Uint8List data,
  ) async {
    _before('putBlobChunk');
    return inner.putBlobChunk(hash, offset, size, mime, data);
  }

  @override
  Future<({int size, String mime, int offset, Uint8List data, bool complete})>
  getBlobChunk(String hash, int offset, {int limit = 196608}) async {
    _before('getBlobChunk');
    final result = await inner.getBlobChunk(hash, offset, limit: limit);
    if (corruptNextBlob && result.data.isNotEmpty) {
      corruptNextBlob = false;
      final bytes = Uint8List.fromList(result.data)..[0] ^= 0xff;
      return (
        size: result.size,
        mime: result.mime,
        offset: result.offset,
        data: bytes,
        complete: result.complete,
      );
    }
    return result;
  }

  @override
  Future<CloudSession> refresh(CloudSession session) async {
    _before('refresh');
    return inner.refresh(session);
  }
}
