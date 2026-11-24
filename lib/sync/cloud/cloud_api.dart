import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum CloudErrorKind {
  unauthorized,
  conflict,
  libraryMismatch,
  notFound,
  rateLimited,
  server,
  network,
  malformed,
}

class CloudApiException implements Exception {
  const CloudApiException(
    this.kind,
    this.message, {
    this.currentRows = const [],
    this.retryAfter,
  });
  final CloudErrorKind kind;
  final String message;
  final List<Map<String, Object?>> currentRows;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

class CloudSession {
  const CloudSession({
    required this.deviceId,
    required this.access,
    required this.accessExp,
    required this.refresh,
  });
  final String deviceId, access, refresh;
  final int accessExp;
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'access': access,
    'accessExp': accessExp,
    'refresh': refresh,
  };
  factory CloudSession.fromJson(Map<String, Object?> j) => CloudSession(
    deviceId: j['deviceId'] as String,
    access: j['access'] as String,
    accessExp: j['accessExp'] as int,
    refresh: j['refresh'] as String,
  );
}

abstract interface class CloudSessionStore {
  Future<CloudSession?> read();
  Future<void> write(CloudSession? session);
}

class MemoryCloudSessionStore implements CloudSessionStore {
  CloudSession? session;
  @override
  Future<CloudSession?> read() async => session;
  @override
  Future<void> write(CloudSession? value) async => session = value;
}

class SecureCloudSessionStore implements CloudSessionStore {
  const SecureCloudSessionStore();
  static const _key = 'notes.cloud.session.v1';
  static const _storage = FlutterSecureStorage();
  @override
  Future<CloudSession?> read() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    try {
      return CloudSession.fromJson(
        (jsonDecode(value) as Map).cast<String, Object?>(),
      );
    } on Object {
      await write(null);
      return null;
    }
  }

  @override
  Future<void> write(CloudSession? session) async {
    if (session == null) {
      await _storage.delete(key: _key);
      return;
    }
    await _storage.write(key: _key, value: jsonEncode(session.toJson()));
  }
}

class CloudRecord {
  const CloudRecord({
    required this.kind,
    required this.id,
    required this.rev,
    required this.seq,
    required this.digest,
    required this.row,
  });
  final String kind, id, digest;
  final int rev, seq;
  final Map<String, Object?> row;
  factory CloudRecord.fromJson(Map<String, Object?> j) => CloudRecord(
    kind: j['kind'] is String ? j['kind'] as String : '',
    id: j['id'] is String ? j['id'] as String : '',
    rev: j['rev'] is int ? j['rev'] as int : -1,
    seq: j['seq'] is int ? j['seq'] as int : -1,
    digest: j['digest'] is String ? j['digest'] as String : '',
    row: j['row'] is Map
        ? (j['row'] as Map).cast<String, Object?>()
        : const <String, Object?>{},
  );
  Map<String, Object?> toJson() => {
    'kind': kind,
    'id': id,
    'rev': rev,
    'seq': seq,
    'digest': digest,
    'row': row,
  };
}

class CloudChanges {
  const CloudChanges(
    this.libraryId,
    this.rows,
    this.next,
    this.more,
    this.head,
  );
  final String libraryId;
  final List<CloudRecord> rows;
  final int next, head;
  final bool more;
}

class CloudLibraryInfo {
  const CloudLibraryInfo({
    required this.libraryId,
    required this.state,
    required this.seq,
    required this.notes,
    required this.folders,
    required this.blobs,
    this.createdAt,
    this.uploaderDeviceId,
  });
  final String libraryId, state;
  final int seq, notes, folders, blobs;
  final String? createdAt, uploaderDeviceId;

  factory CloudLibraryInfo.fromJson(Map<String, Object?> json) {
    final counts = (json['counts'] as Map).cast<String, Object?>();
    return CloudLibraryInfo(
      libraryId: json['libraryId'] as String,
      state: json['state'] as String,
      seq: json['seq'] as int,
      notes: counts['notes'] as int,
      folders: counts['folders'] as int,
      blobs: counts['blobs'] as int,
      createdAt: json['createdAt'] as String?,
      uploaderDeviceId: json['uploaderDeviceId'] as String?,
    );
  }
}

class CloudManifestItem {
  const CloudManifestItem(this.kind, this.id, this.rev, this.digest);
  final String kind, id, digest;
  final int rev;
}

class CloudManifestPage {
  const CloudManifestPage(this.items, this.next, this.more);
  final List<CloudManifestItem> items;
  final String next;
  final bool more;
}

class CloudPushItem {
  const CloudPushItem(this.kind, this.id, this.baseRev, this.digest, this.row);
  final String kind, id, digest;
  final int baseRev;
  final Map<String, Object?> row;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'id': id,
    'baseRev': baseRev,
    'digest': digest,
    'row': row,
  };
}

class CloudPushResult {
  const CloudPushResult(this.kind, this.id, this.rev, this.seq, this.unchanged);
  final String kind, id;
  final int rev, seq;
  final bool unchanged;
}

abstract interface class CloudApi {
  Future<Map<String, Object?>> health();
  Future<Map<String, Object?>> authStart(Uri uri);
  Future<CloudSession> authToken(String code, String verifier);
  Future<void> logout();
  Future<Map<String, Object?>> devices();
  Future<void> revokeDevice(String id);
  Future<Map<String, Object?>> head();
  Future<CloudLibraryInfo> library();
  Future<Map<String, Object?>> initLibrary();
  Future<void> markReady(String libraryId);
  Future<CloudChanges> changes(
    String libraryId,
    int since, {
    int limit = 50,
    int maxBytes = 204800,
  });
  Future<List<CloudPushResult>> push(
    String libraryId,
    String batchId,
    List<CloudPushItem> rows,
  );
  Future<CloudManifestPage> manifest({String? after, int limit = 500});
  Future<({Set<String> missing, Map<String, int> partial})> checkBlobs(
    List<String> hashes,
  );
  Future<int> putBlobChunk(
    String hash,
    int offset,
    int size,
    String mime,
    Uint8List data,
  );
  Future<({int size, String mime, int offset, Uint8List data, bool complete})>
  getBlobChunk(String hash, int offset, {int limit = 196608});
  Future<CloudSession> refresh(CloudSession session);
}

/// HTTP implementation. Bodies and authorization material are never logged.
class HttpCloudApi implements CloudApi {
  HttpCloudApi({
    required this.baseUrl,
    required this.sessions,
    HttpClient? client,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 2 * 1024 * 1024,
  }) : _client = client ?? HttpClient();
  final Uri baseUrl;
  final CloudSessionStore sessions;
  final HttpClient _client;
  final Duration timeout;
  final int maxResponseBytes;
  CloudSession? _cached;
  Future<CloudSession>? _refreshing;

  Uri _uri(String path, [Map<String, String>? query]) =>
      baseUrl.replace(path: '${baseUrl.path}$path', queryParameters: query);
  @override
  Future<Map<String, Object?>> health() =>
      _json('GET', '/v1/health', auth: false);
  @override
  Future<Map<String, Object?>> authStart(Uri uri) =>
      _requestUri('GET', uri, auth: false);
  @override
  Future<CloudSession> authToken(String code, String verifier) async {
    final j = await _json(
      'POST',
      '/v1/auth/token',
      auth: false,
      body: {'code': code, 'verifier': verifier},
    );
    final s = CloudSession.fromJson(j);
    _cached = s;
    await sessions.write(s);
    return s;
  }

  @override
  Future<void> logout() async {
    try {
      await _json('POST', '/v1/auth/logout', body: {});
    } finally {
      _cached = null;
      await sessions.write(null);
    }
  }

  @override
  Future<Map<String, Object?>> devices() => _json('GET', '/v1/devices');
  @override
  Future<void> revokeDevice(String id) async {
    await _json('DELETE', '/v1/devices/${Uri.encodeComponent(id)}');
  }

  @override
  Future<Map<String, Object?>> head() => _json('GET', '/v1/head');
  @override
  Future<CloudLibraryInfo> library() async =>
      CloudLibraryInfo.fromJson(await _json('GET', '/v1/library'));
  @override
  Future<Map<String, Object?>> initLibrary() =>
      _json('POST', '/v1/library/init', body: {});
  @override
  Future<void> markReady(String libraryId) async {
    await _json('POST', '/v1/library/ready', body: {'libraryId': libraryId});
  }

  @override
  Future<CloudChanges> changes(
    String libraryId,
    int since, {
    int limit = 50,
    int maxBytes = 204800,
  }) async {
    final j = await _json(
      'GET',
      '/v1/changes',
      query: {'since': '$since', 'limit': '$limit', 'maxBytes': '$maxBytes'},
    );
    if (j['libraryId'] is! String ||
        j['rows'] is! List ||
        j['next'] is! int ||
        j['head'] is! int ||
        j['more'] is! bool) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Cloud returned an invalid change page.',
      );
    }
    return CloudChanges(
      j['libraryId'] as String,
      [
        for (final r in j['rows'] as List)
          if (r is Map)
            CloudRecord.fromJson(r.cast<String, Object?>())
          else
            throw const CloudApiException(
              CloudErrorKind.malformed,
              'Cloud returned an invalid change row.',
            ),
      ],
      j['next'] as int,
      j['more'] as bool,
      j['head'] as int,
    );
  }

  @override
  Future<List<CloudPushResult>> push(
    String libraryId,
    String batchId,
    List<CloudPushItem> rows,
  ) async {
    final j = await _json(
      'POST',
      '/v1/push',
      body: {
        'libraryId': libraryId,
        'batchId': batchId,
        'rows': [for (final r in rows) r.toJson()],
      },
    );
    return [
      for (final r in j['results'] as List)
        CloudPushResult(
          (r as Map)['kind'] as String,
          r['id'] as String,
          r['rev'] as int,
          r['seq'] as int,
          r['unchanged'] as bool,
        ),
    ];
  }

  @override
  Future<CloudManifestPage> manifest({String? after, int limit = 500}) async {
    final j = await _json(
      'GET',
      '/v1/manifest',
      query: {'after': ?after, 'limit': '$limit'},
    );
    if (j['items'] is! List || j['next'] is! String || j['more'] is! bool) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Cloud returned an invalid manifest page.',
      );
    }
    final items = [
      for (final v in j['items'] as List)
        if (v is Map)
          CloudManifestItem(
            v['kind'] as String,
            v['id'] as String,
            v['rev'] as int,
            v['digest'] as String,
          )
        else
          throw const CloudApiException(
            CloudErrorKind.malformed,
            'Cloud returned an invalid manifest item.',
          ),
    ];
    return CloudManifestPage(items, j['next'] as String, j['more'] as bool);
  }

  @override
  Future<({Set<String> missing, Map<String, int> partial})> checkBlobs(
    List<String> hashes,
  ) async {
    _validateHashes(hashes);
    final j = await _json('POST', '/v1/blobs/check', body: {'hashes': hashes});
    return (
      missing: (j['missing'] as List).cast<String>().toSet(),
      partial: {
        for (final e in (j['partial'] as Map).entries)
          e.key as String: e.value as int,
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
    _validateHash(hash);
    if (offset < 0 ||
        size < 0 ||
        size > 20 * 1024 * 1024 ||
        data.length > 96 * 1024) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Attachment upload is invalid.',
      );
    }
    final j = await _json(
      'PUT',
      '/v1/blobs/$hash',
      body: {
        'offset': offset,
        'size': size,
        'mime': mime,
        'data': base64Encode(data),
      },
    );
    return j['offset'] as int;
  }

  @override
  Future<({int size, String mime, int offset, Uint8List data, bool complete})>
  getBlobChunk(String hash, int offset, {int limit = 196608}) async {
    _validateHash(hash);
    if (offset < 0 || limit < 1 || limit > 192 * 1024) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Attachment request is invalid.',
      );
    }
    final j = await _json(
      'GET',
      '/v1/blobs/$hash',
      query: {'offset': '$offset', 'limit': '$limit'},
    );
    return (
      size: j['size'] as int,
      mime: j['mime'] as String,
      offset: j['offset'] as int,
      data: base64Decode(j['data'] as String),
      complete: j['complete'] as bool,
    );
  }

  @override
  Future<CloudSession> refresh(CloudSession session) async {
    if (_cached != null && _cached!.access != session.access) return _cached!;
    final pending = _refreshing;
    if (pending != null) return pending;
    final future = () async {
      try {
        final j = await _json(
          'POST',
          '/v1/auth/refresh',
          auth: false,
          body: {'refresh': session.refresh},
        );
        final s = CloudSession.fromJson(j);
        _cached = s;
        await sessions.write(s);
        return s;
      } on Object {
        _cached = null;
        await sessions.write(null);
        throw const CloudApiException(
          CloudErrorKind.unauthorized,
          'You are signed out of cloud sync. Sign in again.',
        );
      }
    }();
    _refreshing = future;
    try {
      return await future;
    } finally {
      _refreshing = null;
    }
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    bool auth = true,
    Map<String, String>? query,
    Object? body,
  }) => _request(method, _uri(path, query), auth: auth, body: body);
  Future<Map<String, Object?>> _request(
    String method,
    Uri uri, {
    bool auth = true,
    Object? body,
  }) async {
    if (uri.userInfo.isNotEmpty ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                (uri.host == '127.0.0.1' || uri.host == 'localhost')))) {
      throw const CloudApiException(
        CloudErrorKind.network,
        'Cloud connection must use HTTPS.',
      );
    }
    var session = auth ? (_cached ??= await sessions.read()) : null;
    var result = await _send(method, uri, body, session).timeout(timeout);
    if (result.statusCode == 401 && auth && session != null) {
      try {
        session = await refresh(session);
      } on CloudApiException {
        rethrow;
      }
      result = await _send(method, uri, body, session).timeout(timeout);
    }
    if (result.statusCode < 200 || result.statusCode >= 300) {
      final kind = switch (result.statusCode) {
        401 => CloudErrorKind.unauthorized,
        404 => CloudErrorKind.notFound,
        409 => CloudErrorKind.conflict,
        429 => CloudErrorKind.rateLimited,
        >= 500 => CloudErrorKind.server,
        _ => CloudErrorKind.malformed,
      };
      final decoded = _tryJson(result.bytes);
      final err = decoded?['error'];
      throw CloudApiException(
        err == 'library' ? CloudErrorKind.libraryMismatch : kind,
        switch (err == 'library' ? CloudErrorKind.libraryMismatch : kind) {
          CloudErrorKind.unauthorized => 'You are signed out of cloud sync.',
          CloudErrorKind.conflict => 'Cloud records changed on another device.',
          CloudErrorKind.libraryMismatch =>
            'The linked cloud library has changed.',
          CloudErrorKind.notFound => 'The requested cloud item was not found.',
          CloudErrorKind.rateLimited => 'Cloud sync is temporarily busy.',
          CloudErrorKind.server => 'Cloud sync is temporarily unavailable.',
          _ => 'Cloud request could not be completed.',
        },
        currentRows: [
          for (final r in decoded?['conflicts'] as List? ?? const [])
            if (r is Map) r.cast<String, Object?>(),
        ],
        retryAfter: result.retryAfter == null
            ? null
            : _parseRetryAfter(result.retryAfter!),
      );
    }
    final decoded = _tryJson(result.bytes);
    if (decoded == null) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Cloud returned an invalid response.',
      );
    }
    return decoded;
  }

  Future<Map<String, Object?>> _requestUri(
    String method,
    Uri uri, {
    bool auth = true,
    Object? body,
  }) => _request(method, uri, auth: auth, body: body);
  Future<({int statusCode, Uint8List bytes, String? retryAfter})> _send(
    String method,
    Uri uri,
    Object? body,
    CloudSession? session,
  ) async {
    try {
      final total = Stopwatch()..start();
      final encodedBody = body == null ? null : jsonEncode(body);
      if (encodedBody != null && utf8.encode(encodedBody).length > 256 * 1024) {
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'Cloud request is too large.',
        );
      }
      final req = await _client.openUrl(method, uri).timeout(timeout);
      if (total.elapsed > timeout) throw _requestTimeout();
      req.followRedirects = false;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(encodedBody);
      }
      if (session != null) {
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${session.access}',
        );
      }
      final resp = await req.close().timeout(timeout);
      if (total.elapsed > timeout) throw _requestTimeout();
      if (resp.contentLength > maxResponseBytes) {
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'Cloud response is too large.',
        );
      }
      final builder = BytesBuilder();
      await for (final chunk in resp.timeout(timeout)) {
        if (total.elapsed > timeout) throw _requestTimeout();
        builder.add(chunk);
        if (builder.length > maxResponseBytes) {
          throw const CloudApiException(
            CloudErrorKind.malformed,
            'Cloud response is too large.',
          );
        }
      }
      if (total.elapsed > timeout) throw _requestTimeout();
      return (
        statusCode: resp.statusCode,
        bytes: builder.takeBytes(),
        retryAfter: resp.headers.value(HttpHeaders.retryAfterHeader),
      );
    } on CloudApiException {
      rethrow;
    } on Object {
      throw const CloudApiException(
        CloudErrorKind.network,
        'Could not reach cloud sync.',
      );
    }
  }

  CloudApiException _requestTimeout() => const CloudApiException(
    CloudErrorKind.network,
    'Cloud request timed out.',
  );

  void _validateHashes(List<String> hashes) {
    if (hashes.length > 100) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Too many attachment hashes.',
      );
    }
    for (final hash in hashes) {
      _validateHash(hash);
    }
  }

  void _validateHash(String hash) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Attachment hash is invalid.',
      );
    }
  }

  Map<String, Object?>? _tryJson(Uint8List b) {
    try {
      final v = jsonDecode(utf8.decode(b));
      return v is Map ? v.cast<String, Object?>() : null;
    } on Object {
      return null;
    }
  }

  void close() => _client.close(force: true);

  Duration? _parseRetryAfter(String value) {
    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 1800));
    try {
      final delay = HttpDate.parse(value).difference(DateTime.now().toUtc());
      return delay.isNegative ? Duration.zero : delay;
    } on FormatException {
      return null;
    }
  }
}
