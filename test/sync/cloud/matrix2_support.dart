import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/models.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';

import '../../support/fake_cloud_server.dart';

const matrixId1 = '00000000-0000-4000-8000-000000000101';
const matrixId2 = '00000000-0000-4000-8000-000000000102';
const matrixFolderId = '00000000-0000-4000-8000-000000000103';
const matrixLibraryId = 'test-library';
const matrixEpoch = 1795500000000;

AppDatabase matrixDb({int now = matrixEpoch}) =>
    AppDatabase.open(null, wallClock: () => now);

/// All persisted SQLite table contents, including metadata and sync bookkeeping.
/// The deterministic encoding makes before/after comparisons byte stable.
String fullDatabaseDump(AppDatabase db) {
  final tables = db.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
  );
  return jsonEncode([
    for (final table in tables)
      [
        table['name'],
        [
          for (final row in db.select('SELECT * FROM "${table['name']}"'))
            {
              for (final key in row.keys)
                key: row[key] is Uint8List
                    ? base64Encode(row[key] as Uint8List)
                    : row[key],
            },
        ],
      ],
  ]);
}

CloudService matrixService({
  required NoteRepository repo,
  required CloudApi api,
  required CloudSessionStore sessions,
  required String dataDir,
}) => CloudService(
  repo: repo,
  api: api,
  sessions: sessions,
  dataDir: dataDir,
  deviceName: 'Synthetic test device',
  loginLauncher: null,
  unavailable: false,
);

MemoryCloudSessionStore matrixSessions({String deviceId = 'test-device'}) =>
    MemoryCloudSessionStore()
      ..session = CloudSession(
        deviceId: deviceId,
        access: 'test-access',
        accessExp: 9999999999,
        refresh: 'test-refresh',
      );

Future<Directory> matrixTempDir() async {
  final dir = await Directory.systemTemp.createTemp('notes-cloud-matrix-');
  return dir;
}

void cloneServerRowsTo(FakeCloudServer server, NoteRepository destination) {
  destination.db.transaction(() {
    for (final record in server.records.values) {
      if (record.kind == 'note') {
        destination.writeRecord(NoteRecord.fromJson(record.row));
      } else if (record.kind == 'folder') {
        destination.writeFolderRecord(FolderRecord.fromJson(record.row));
      }
    }
    for (final entry in server.blobs.entries) {
      destination.storeCloudAttachment(
        entry.key,
        server.blobMimes[entry.key] ?? 'application/octet-stream',
        entry.value,
      );
    }
  });
}

/// Faults at API request boundaries while retaining the fake server's normal
/// state and behavior for all unaffected requests.
class MatrixServer extends FakeCloudServer {
  MatrixServer({super.deviceId});

  String? wrongLibraryOnChanges;
  int? rewoundSequence;
  bool duplicateIdsOnNextPage = false;
  bool wrongDigestOnNextPage = false;
  bool wrongRecordIdOnNextPage = false;
  bool giantRowOnNextPage = false;
  bool unknownKindOnNextPage = false;
  bool endlessPage = false;
  bool hangNextChanges = false;
  final never = CompleterNever();

  @override
  Future<CloudChanges> changes(
    String id,
    int since, {
    int limit = 50,
    int maxBytes = 204800,
  }) async {
    if (hangNextChanges) {
      hangNextChanges = false;
      await never.future;
    }
    final page = await super.changes(
      id,
      since,
      limit: limit,
      maxBytes: maxBytes,
    );
    if (wrongLibraryOnChanges != null || rewoundSequence != null) {
      return CloudChanges(
        wrongLibraryOnChanges ?? page.libraryId,
        page.rows,
        rewoundSequence ?? page.next,
        page.more,
        page.head,
      );
    }
    if (page.rows.isEmpty) return page;
    var rows = [...page.rows];
    if (duplicateIdsOnNextPage) {
      duplicateIdsOnNextPage = false;
      rows = [rows.first, rows.first];
    }
    if (wrongDigestOnNextPage) {
      wrongDigestOnNextPage = false;
      final r = rows.first;
      rows[0] = CloudRecord(
        kind: r.kind,
        id: r.id,
        rev: r.rev,
        seq: r.seq,
        digest: '0' * 64,
        row: r.row,
      );
    }
    if (wrongRecordIdOnNextPage) {
      wrongRecordIdOnNextPage = false;
      final r = rows.first;
      rows[0] = CloudRecord(
        kind: r.kind,
        id: r.id,
        rev: r.rev,
        seq: r.seq,
        digest: r.digest,
        row: {...r.row, 'id': matrixId1},
      );
    }
    if (giantRowOnNextPage) {
      giantRowOnNextPage = false;
      final r = rows.first;
      rows[0] = CloudRecord(
        kind: r.kind,
        id: r.id,
        rev: r.rev,
        seq: r.seq,
        digest: r.digest,
        row: {...r.row, 'title': 'x' * (3 * 1024 * 1024)},
      );
    }
    if (unknownKindOnNextPage) {
      unknownKindOnNextPage = false;
      final r = rows.first;
      rows[0] = CloudRecord(
        kind: 'unknown',
        id: r.id,
        rev: r.rev,
        seq: r.seq,
        digest: r.digest,
        row: r.row,
      );
    }
    return CloudChanges(
      page.libraryId,
      rows,
      endlessPage ? since : page.next,
      endlessPage || page.more,
      page.head,
    );
  }
}

class CompleterNever {
  final _completer = Completer<void>();
  Future<void> get future => _completer.future;
}
