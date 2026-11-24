import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:notes/sync/cloud/cloud_api.dart';

/// In-memory model of the Worker/SQL contract. Faults are injected at API
/// request boundaries; [dropNextPushResponse] commits before losing the reply.
class FakeCloudServer implements CloudApi {
  FakeCloudServer({this.deviceId = 'test-device'});

  final String deviceId;
  String libraryId = 'test-library';
  String state = 'ready';
  String? uploaderDeviceId;
  String createdAt = '2026-01-01T00:00:00.000Z';
  int seq = 0;
  int requestCount = 0;
  int? failAtRequest;
  int? failStatusAtRequest;
  String? failRetryAfter;
  bool dropNextPushResponse = false;
  bool duplicateChanges = false;
  bool reverseChanges = false;
  bool headStale = false;
  bool malformedNextResponse = false;
  Future<void> Function()? beforeNextPush;
  Duration responseDelay = Duration.zero;
  final records = <String, CloudRecord>{};
  final blobs = <String, Uint8List>{};
  final blobMimes = <String, String>{};
  final partialBlobs = <String, int>{};
  final _blobParts = <String, Uint8List>{};
  final _devices = <String, Map<String, Object?>>{};
  HttpServer? _httpServer;
  Future<void> _lockTail = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _lockTail;
    final done = Completer<void>();
    _lockTail = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<Uri> startHttpServer() async {
    _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _httpServer!.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      try {
        await _before();
        if (request.uri.path == '/v1/health' && request.method == 'GET') {
          response.write(jsonEncode({'ok': true, 'v': 1, 'env': 'test'}));
        } else if (request.uri.path == '/v1/head' && request.method == 'GET') {
          if (request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer test-access') {
            response.statusCode = HttpStatus.unauthorized;
            response.write(jsonEncode(_error('auth', 'Sign in.')));
          } else {
            response.write(
              jsonEncode({'libraryId': libraryId, 'state': state, 'seq': seq}),
            );
          }
        } else {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode(_error('not_found', 'Missing.')));
        }
      } on CloudApiException catch (e) {
        response.statusCode = switch (e.kind) {
          CloudErrorKind.unauthorized => 401,
          CloudErrorKind.conflict || CloudErrorKind.libraryMismatch => 409,
          CloudErrorKind.rateLimited => 429,
          CloudErrorKind.server => 503,
          _ => 500,
        };
        if (e.retryAfter != null) {
          response.headers.set(
            HttpHeaders.retryAfterHeader,
            '${e.retryAfter!.inSeconds}',
          );
        }
        response.write(jsonEncode(_error('injected', e.message)));
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
    if (requestCount == failStatusAtRequest) {
      final delay = int.tryParse(failRetryAfter ?? '');
      throw CloudApiException(
        delay == null ? CloudErrorKind.server : CloudErrorKind.rateLimited,
        'Injected HTTP failure.',
        retryAfter: delay == null ? null : Duration(seconds: delay),
      );
    }
  }

  Map<String, Object?> _error(String error, String message) => {
    'error': error,
    'message': message,
  };

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
    _devices[deviceId] = {
      'id': deviceId,
      'name': 'Test device',
      'createdAt': createdAt,
      'lastSeen': createdAt,
    };
    return CloudSession(
      deviceId: deviceId,
      access: 'test-access',
      accessExp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 43200,
      refresh: 'test-refresh',
    );
  }

  @override
  Future<void> logout() async {
    await _before();
    _devices.remove(deviceId);
  }

  @override
  Future<Map<String, Object?>> devices() async {
    await _before();
    return {'devices': _devices.values.toList()};
  }

  @override
  Future<void> revokeDevice(String id) async {
    await _before();
    _devices.remove(id);
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
      createdAt: createdAt,
      uploaderDeviceId: uploaderDeviceId,
    );
  }

  @override
  Future<Map<String, Object?>> initLibrary() async {
    await _before();
    if (state != 'empty') {
      throw const CloudApiException(
        CloudErrorKind.conflict,
        'Cloud library already exists.',
      );
    }
    state = 'uploading';
    uploaderDeviceId = deviceId;
    return {'libraryId': libraryId, 'deviceId': deviceId};
  }

  @override
  Future<void> markReady(String id) async {
    await _before();
    if (id != libraryId ||
        uploaderDeviceId != deviceId ||
        state != 'uploading') {
      throw const CloudApiException(
        CloudErrorKind.libraryMismatch,
        'Cloud library is unavailable.',
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
    if (limit < 1 || maxBytes < 1 || since < 0) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Invalid page size.',
      );
    }
    limit = limit.clamp(1, 100);
    maxBytes = maxBytes.clamp(1024, 256 * 1024);
    var all = records.values.where((r) => r.seq > since).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    if (reverseChanges) all = all.reversed.toList();
    if (duplicateChanges && all.isNotEmpty) all = [all.first, ...all];
    final rows = <CloudRecord>[];
    var bytes = 256;
    for (final row in all) {
      final size =
          utf8.encode(jsonEncode(row.toJson())).length + (rows.isEmpty ? 0 : 1);
      if (rows.isEmpty && bytes + size > maxBytes) {
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'row_too_large: One record exceeds the requested page size.',
        );
      }
      if (rows.isNotEmpty &&
          (rows.length >= limit || bytes + size > maxBytes)) {
        break;
      }
      rows.add(row);
      bytes += size;
    }
    final more = rows.length < all.length;
    return CloudChanges(
      libraryId,
      rows,
      rows.isEmpty ? since : rows.last.seq,
      more,
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
    return _locked(() async {
      if (id != libraryId) {
        throw const CloudApiException(
          CloudErrorKind.libraryMismatch,
          'Wrong library.',
        );
      }
      if (state == 'uploading' && uploaderDeviceId != deviceId) {
        throw const CloudApiException(
          CloudErrorKind.conflict,
          'Library is uploading.',
        );
      }
      final keys = <String>{};
      final conflicts = <Map<String, Object?>>[];
      for (final item in incoming) {
        final key = '${item.kind}:${item.id}';
        if (!keys.add(key)) {
          throw const CloudApiException(
            CloudErrorKind.malformed,
            'Duplicate record.',
          );
        }
        final old = records[key];
        if (old != null &&
            old.digest != item.digest &&
            old.rev != item.baseRev) {
          conflicts.add(old.toJson());
        } else if (old == null && item.baseRev != 0) {
          conflicts.add({'kind': item.kind, 'id': item.id, 'missing': true});
        }
      }
      if (conflicts.isNotEmpty) {
        throw CloudApiException(
          CloudErrorKind.conflict,
          'Cloud records changed on another device.',
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
          row: Map<String, Object?>.from(item.row),
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
    });
  }

  @override
  Future<CloudManifestPage> manifest({String? after, int limit = 500}) async {
    await _before();
    limit = limit.clamp(1, 500);
    final all = records.values.toList()
      ..sort((a, b) => '${a.kind}:${a.id}'.compareTo('${b.kind}:${b.id}'));
    final start = after == null
        ? 0
        : all
              .indexWhere((r) => '${r.kind}:${r.id}'.compareTo(after) > 0)
              .let((i) => i < 0 ? all.length : i);
    final items = [
      for (final r in all.skip(start).take(limit))
        CloudManifestItem(r.kind, r.id, r.rev, r.digest),
    ];
    return CloudManifestPage(
      items,
      items.isEmpty ? (after ?? '') : '${items.last.kind}:${items.last.id}',
      start + items.length < all.length,
    );
  }

  @override
  Future<({Set<String> missing, Map<String, int> partial})> checkBlobs(
    List<String> hashes,
  ) async {
    await _before();
    if (hashes.length > 100) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Too many hashes.',
      );
    }
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
    if (size < 0 ||
        size > 20 * 1024 * 1024 ||
        data.length > 96 * 1024 ||
        offset < 0 ||
        offset > size) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Invalid blob chunk.',
      );
    }
    if (state == 'uploading' && uploaderDeviceId != deviceId) {
      throw const CloudApiException(
        CloudErrorKind.conflict,
        'Library is uploading.',
      );
    }
    final existing = blobs[hash] ?? _blobParts[hash] ?? Uint8List(0);
    if (blobs.containsKey(hash)) return existing.length;
    if (offset != existing.length) return existing.length;
    if (partialBlobs.containsKey(hash) &&
        (partialBlobs[hash] != existing.length ||
            _blobMimes[hash] != mime ||
            _blobSizes[hash] != size)) {
      return existing.length;
    }
    final next = Uint8List.fromList([...existing, ...data]);
    if (next.length > size) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Blob exceeds size.',
      );
    }
    _blobMimes[hash] = mime;
    _blobSizes[hash] = size;
    if (next.length == size) {
      if (sha256.convert(next).toString() != hash) {
        partialBlobs.remove(hash);
        _blobParts.remove(hash);
        _blobMimes.remove(hash);
        _blobSizes.remove(hash);
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'Blob hash mismatch.',
        );
      }
      blobs[hash] = next;
      blobMimes[hash] = mime;
      partialBlobs.remove(hash);
      _blobParts.remove(hash);
      _blobMimes.remove(hash);
      _blobSizes.remove(hash);
      return next.length;
    }
    partialBlobs[hash] = next.length;
    _blobParts[hash] = next;
    return next.length;
  }

  final _blobMimes = <String, String>{};
  final _blobSizes = <String, int>{};

  @override
  Future<({int size, String mime, int offset, Uint8List data, bool complete})>
  getBlobChunk(String hash, int offset, {int limit = 196608}) async {
    await _before();
    final b = blobs[hash];
    if (b == null) {
      throw const CloudApiException(CloudErrorKind.notFound, 'Blob not found.');
    }
    if (offset < 0 || limit < 1 || limit > 192 * 1024 || offset > b.length) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Invalid blob range.',
      );
    }
    final end = (offset + limit).clamp(0, b.length);
    return (
      size: b.length,
      mime: blobMimes[hash] ?? 'application/octet-stream',
      offset: offset,
      data: Uint8List.fromList(b.sublist(offset, end)),
      complete: end == b.length,
    );
  }

  @override
  Future<CloudSession> refresh(CloudSession session) async {
    await _before();
    return session;
  }
}

extension<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
}
