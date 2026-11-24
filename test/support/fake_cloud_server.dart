import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:notes/sync/cloud/cloud_api.dart';

/// In-memory protocol fake for synthetic tests. Faults apply at request
/// boundaries, including after a committed push to model a lost response.
class FakeCloudServer implements CloudApi {
  String libraryId = 'test-library';
  String state = 'ready';
  int seq = 0;
  int requestCount = 0;
  int? failAtRequest;
  bool dropNextPushResponse = false;
  bool duplicateChanges = false;
  bool reverseChanges = false;
  Future<void> Function()? beforeNextPush;
  Duration responseDelay = Duration.zero;
  final records = <String, CloudRecord>{};
  final blobs = <String, Uint8List>{};
  final partialBlobs = <String, int>{};
  final _blobParts = <String, Uint8List>{};
  HttpServer? _httpServer;

  Future<Uri> startHttpServer() async {
    _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _httpServer!.listen((request) async {
      await _before();
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (request.uri.path == '/v1/health') {
        response.write(jsonEncode({'ok': true, 'v': 1, 'env': 'test'}));
      } else if (request.uri.path == '/v1/head') {
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
            'Bearer test-access') {
          response.statusCode = HttpStatus.unauthorized;
          response.write(
            jsonEncode({'error': 'unauthorized', 'message': 'Sign in.'}),
          );
        } else {
          response.write(
            jsonEncode({'libraryId': libraryId, 'state': state, 'seq': seq}),
          );
        }
      } else {
        response.statusCode = HttpStatus.notFound;
        response.write(
          jsonEncode({'error': 'not_found', 'message': 'Missing.'}),
        );
      }
      await response.close();
    });
    return Uri(scheme: 'http', host: '127.0.0.1', port: _httpServer!.port);
  }

  Future<void> closeHttpServer() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  Future<void> _before() async {
    requestCount++;
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    if (requestCount == failAtRequest) {
      throw const CloudApiException(
        CloudErrorKind.network,
        'Injected failure.',
      );
    }
  }

  @override
  Future<Map<String, Object?>> health() async {
    await _before();
    return {'ok': true, 'v': 1, 'env': 'test'};
  }

  @override
  Future<Map<String, Object?>> authStart(Uri uri) async {
    await _before();
    return {'ok': true};
  }

  @override
  Future<CloudSession> authToken(String code, String verifier) async {
    await _before();
    return const CloudSession(
      deviceId: 'test-device',
      access: 'test-access',
      accessExp: 9999999999,
      refresh: 'test-refresh',
    );
  }

  @override
  Future<void> logout() async {
    await _before();
  }

  @override
  Future<Map<String, Object?>> devices() async {
    await _before();
    return {'devices': <Object>[]};
  }

  @override
  Future<void> revokeDevice(String id) async {
    await _before();
  }

  @override
  Future<Map<String, Object?>> head() async {
    await _before();
    return {'libraryId': libraryId, 'state': state, 'seq': seq};
  }

  @override
  Future<CloudLibraryInfo> library() async {
    await _before();
    return CloudLibraryInfo(
      libraryId: libraryId,
      state: state,
      seq: seq,
      notes: records.values.where((r) => r.kind == 'note').length,
      folders: records.values.where((r) => r.kind == 'folder').length,
      blobs: blobs.length,
    );
  }

  @override
  Future<Map<String, Object?>> initLibrary() async {
    await _before();
    state = 'uploading';
    return {'libraryId': libraryId, 'deviceId': 'test-device'};
  }

  @override
  Future<void> markReady(String id) async {
    await _before();
    if (id != libraryId) {
      throw const CloudApiException(
        CloudErrorKind.libraryMismatch,
        'Wrong library.',
      );
    }
    state = 'ready';
  }

  @override
  Future<CloudChanges> changes(
    String id,
    int since, {
    int limit = 50,
    int maxBytes = 204800,
  }) async {
    await _before();
    if (id != libraryId) {
      throw const CloudApiException(
        CloudErrorKind.libraryMismatch,
        'Wrong library.',
      );
    }
    var rows = records.values.where((r) => r.seq > since).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    if (reverseChanges) rows = rows.reversed.toList();
    rows = rows.take(limit).toList();
    if (duplicateChanges && rows.isNotEmpty) rows = [rows.first, ...rows];
    return CloudChanges(
      libraryId,
      rows,
      rows.isEmpty ? since : rows.last.seq,
      false,
      seq,
    );
  }

  @override
  Future<List<CloudPushResult>> push(
    String id,
    String batchId,
    List<CloudPushItem> incoming,
  ) async {
    await _before();
    final hook = beforeNextPush;
    beforeNextPush = null;
    if (hook != null) await hook();
    if (id != libraryId) {
      throw const CloudApiException(
        CloudErrorKind.libraryMismatch,
        'Wrong library.',
      );
    }
    final conflicts = <Map<String, Object?>>[];
    for (final item in incoming) {
      final old = records['${item.kind}:${item.id}'];
      if (old != null && old.digest != item.digest && old.rev != item.baseRev) {
        conflicts.add(old.toJson());
      }
      if (old == null && item.baseRev != 0) {
        conflicts.add({'kind': item.kind, 'id': item.id});
      }
    }
    if (conflicts.isNotEmpty) {
      throw CloudApiException(
        CloudErrorKind.conflict,
        'Revision conflict.',
        currentRows: conflicts,
      );
    }
    final out = <CloudPushResult>[];
    for (final item in incoming) {
      final key = '${item.kind}:${item.id}';
      final old = records[key];
      if (old?.digest == item.digest) {
        out.add(CloudPushResult(item.kind, item.id, old!.rev, old.seq, true));
        continue;
      }
      seq++;
      final rev = (old?.rev ?? 0) + 1;
      records[key] = CloudRecord(
        kind: item.kind,
        id: item.id,
        rev: rev,
        seq: seq,
        digest: item.digest,
        row: item.row,
      );
      out.add(CloudPushResult(item.kind, item.id, rev, seq, false));
    }
    if (dropNextPushResponse) {
      dropNextPushResponse = false;
      throw const CloudApiException(
        CloudErrorKind.network,
        'Injected lost response.',
      );
    }
    return out;
  }

  @override
  Future<List<CloudManifestItem>> manifest({
    String? after,
    int limit = 500,
  }) async {
    await _before();
    final all = records.values.toList()
      ..sort((a, b) => '${a.kind}:${a.id}'.compareTo('${b.kind}:${b.id}'));
    final from = after == null
        ? 0
        : all
              .indexWhere((r) => '${r.kind}:${r.id}'.compareTo(after) > 0)
              .clamp(0, all.length);
    return [
      for (final r in all.skip(from).take(limit))
        CloudManifestItem(r.kind, r.id, r.rev, r.digest),
    ];
  }

  @override
  Future<({Set<String> missing, Map<String, int> partial})> checkBlobs(
    List<String> hashes,
  ) async {
    await _before();
    return (
      missing: {
        for (final h in hashes)
          if (!blobs.containsKey(h) && !partialBlobs.containsKey(h)) h,
      },
      partial: {
        for (final h in hashes)
          if (partialBlobs.containsKey(h)) h: partialBlobs[h]!,
      },
    );
  }

  @override
  Future<int> putBlobChunk(
    String hash,
    int offset,
    int size,
    String mime,
    Uint8List data,
  ) async {
    await _before();
    final existing = blobs[hash] ?? _blobParts[hash] ?? Uint8List(0);
    if (offset != existing.length) return existing.length;
    final next = Uint8List.fromList([...existing, ...data]);
    if (next.length == size) {
      if (sha256.convert(next).toString() != hash) {
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'Blob hash mismatch.',
        );
      }
      blobs[hash] = next;
      partialBlobs.remove(hash);
      _blobParts.remove(hash);
      return next.length;
    }
    partialBlobs[hash] = next.length;
    _blobParts[hash] = next;
    return next.length;
  }

  @override
  Future<({int size, String mime, int offset, Uint8List data, bool complete})>
  getBlobChunk(String hash, int offset, {int limit = 196608}) async {
    await _before();
    final b = blobs[hash];
    if (b == null) {
      throw const CloudApiException(CloudErrorKind.notFound, 'Blob not found.');
    }
    final end = (offset + limit).clamp(0, b.length);
    return (
      size: b.length,
      mime: 'application/octet-stream',
      offset: offset,
      data: Uint8List.sublistView(b, offset, end),
      complete: end == b.length,
    );
  }

  @override
  Future<CloudSession> refresh(CloudSession session) async {
    await _before();
    return session;
  }
}
