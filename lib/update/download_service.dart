import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'update_http.dart';

/// Lets the caller cancel a running download.
class CancelToken {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void _onCancel(void Function() l) {
    if (_cancelled) {
      l();
    } else {
      _listeners.add(l);
    }
  }
}

enum DownloadFailure {
  cancelled,
  offline,
  interrupted,
  http,
  contentType,
  diskSpace,
  permission,
  sizeMismatch,
  checksumMismatch,
  unsafeName,
}

class DownloadException implements Exception {
  const DownloadException(this.kind, this.message);
  final DownloadFailure kind;
  final String message;

  @override
  String toString() => 'DownloadException(${kind.name}): $message';
}

/// Free bytes on the volume holding [path], or null when unknown.
typedef FreeSpaceProbe = Future<int?> Function(String path);

/// `df` based probe for Linux. Null on any failure (the download then simply
/// runs, and a full disk surfaces as a write error).
Future<int?> dfFreeSpace(String path) async {
  try {
    final r = await Process.run('df', ['-B1', '--output=avail', path]);
    if (r.exitCode != 0) return null;
    final lines = (r.stdout as String).trim().split('\n');
    return lines.length < 2 ? null : int.tryParse(lines.last.trim());
  } on Object {
    return null;
  }
}

final _safeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Streams an update artifact to disk and proves it is the one the signed
/// manifest described. Writes `<name>.part`, enforces the declared size while
/// streaming, and renames to the final name only after size and SHA-256 match.
/// A partial file never survives a failure or a cancel.
class DownloadService {
  DownloadService(
    this._http, {
    this.freeSpace,
    this.idleTimeout = const Duration(seconds: 30),
    this.headerTimeout = const Duration(seconds: 30),
    this.spaceMargin = 16 * 1024 * 1024,
  });

  final UpdateHttp _http;
  final FreeSpaceProbe? freeSpace;

  /// Longest wait for the next chunk. A 40 MB download has no overall limit.
  final Duration idleTimeout;

  /// Longest wait for the server's response headers (and redirects).
  final Duration headerTimeout;

  /// Extra free space required beyond the artifact size.
  final int spaceMargin;

  Future<File> download({
    required Uri url,
    required Directory dir,
    required String filename,
    required String sha256Hex,
    required int size,
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    if (!_safeName.hasMatch(filename) || filename.contains('..')) {
      throw const DownloadException(
        DownloadFailure.unsafeName,
        'The update file name is not valid.',
      );
    }
    final token = cancel ?? CancelToken();
    final finalFile = File('${dir.path}/$filename');
    final part = File('${dir.path}/$filename.part');
    try {
      await dir.create(recursive: true);
      if (await finalFile.exists()) {
        // A finished earlier download is reused only if it still proves out.
        if (await _matches(finalFile, size, sha256Hex)) {
          onProgress?.call(size, size);
          return finalFile;
        }
        await finalFile.delete();
      }
      if (await part.exists()) await part.delete();
      final free = await freeSpace?.call(dir.path);
      if (free != null && free < size + spaceMargin) {
        throw DownloadException(
          DownloadFailure.diskSpace,
          'Not enough free space: about ${_mb(size + spaceMargin)} MB '
          'is needed.',
        );
      }
      if (token.isCancelled) throw _cancelled;
      await _stream(url, part, size, sha256Hex, onProgress, token);
      await part.rename(finalFile.path);
      return finalFile;
    } on FileSystemException catch (e) {
      await _discard(part);
      throw _fromFileSystem(e);
    } catch (_) {
      await _discard(part);
      rethrow;
    }
  }

  static const _cancelled = DownloadException(
    DownloadFailure.cancelled,
    'The download was cancelled.',
  );

  Future<void> _stream(
    Uri url,
    File part,
    int size,
    String sha256Hex,
    void Function(int, int)? onProgress,
    CancelToken token,
  ) async {
    final UpdateResponse response;
    // The wait for headers is bounded and Cancel works during it. A response
    // that arrives after either is closed so no connection is leaked.
    final cancelled = Completer<UpdateResponse>();
    token._onCancel(() {
      if (!cancelled.isCompleted) cancelled.completeError(_cancelled);
    });
    final pending = getFollowingRedirects(
      _http,
      url,
      headers: const {'Accept-Encoding': 'identity'},
    );
    try {
      response = await Future.any([pending, cancelled.future])
          .timeout(headerTimeout);
    } on UpdateOfflineException {
      throw const DownloadException(
        DownloadFailure.offline,
        'No network connection.',
      );
    } on UpdateProtocolException catch (e) {
      throw DownloadException(DownloadFailure.http, e.message);
    } on TimeoutException {
      unawaited(pending.then((r) => r.close(), onError: (Object _) {}));
      throw const DownloadException(
        DownloadFailure.interrupted,
        'The server did not answer in time.',
      );
    } on DownloadException {
      unawaited(pending.then((r) => r.close(), onError: (Object _) {}));
      rethrow;
    }
    token._onCancel(() => unawaited(response.close()));
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    IOSink? sink;
    try {
      if (response.status != 200) {
        throw DownloadException(
          DownloadFailure.http,
          'The server answered with status ${response.status}.',
        );
      }
      final type = (response.headers['content-type'] ?? '').toLowerCase();
      if (type.contains('text/html') || type.contains('json')) {
        throw const DownloadException(
          DownloadFailure.contentType,
          'The server sent a web page instead of the update file.',
        );
      }
      final declared = int.tryParse(response.headers['content-length'] ?? '');
      if (declared != null &&
          !response.headers.containsKey('content-encoding') &&
          declared != size) {
        throw const DownloadException(
          DownloadFailure.sizeMismatch,
          'The file is not the size the release declares.',
        );
      }
      sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.body.timeout(idleTimeout)) {
          if (token.isCancelled) throw _cancelled;
          received += chunk.length;
          if (received > size) {
            throw const DownloadException(
              DownloadFailure.sizeMismatch,
              'The file is larger than the release declares.',
            );
          }
          hash.add(chunk);
          sink.add(chunk);
          await sink.flush();
          onProgress?.call(received, size);
        }
      } on TimeoutException {
        throw const DownloadException(
          DownloadFailure.interrupted,
          'The download stalled.',
        );
      } on SocketException {
        throw const DownloadException(
          DownloadFailure.interrupted,
          'The connection was interrupted.',
        );
      } on HttpException {
        throw token.isCancelled
            ? _cancelled
            : const DownloadException(
                DownloadFailure.interrupted,
                'The connection was interrupted.',
              );
      }
      if (token.isCancelled) throw _cancelled;
      await sink.flush();
      await sink.close();
      sink = null;
      hash.close();
      if (received != size) {
        throw const DownloadException(
          DownloadFailure.interrupted,
          'The download ended early.',
        );
      }
      if (digest.value.toString() != sha256Hex) {
        throw const DownloadException(
          DownloadFailure.checksumMismatch,
          'The downloaded file does not match its checksum.',
        );
      }
    } finally {
      try {
        await sink?.close();
      } on Object {
        // The write already failed; the caller discards the partial file.
      }
      await response.close();
    }
  }

  Future<bool> _matches(File f, int size, String sha256Hex) async {
    if (await f.length() != size) return false;
    final d = await sha256.bind(f.openRead()).first;
    return d.toString() == sha256Hex;
  }

  Future<void> _discard(File part) async {
    try {
      if (await part.exists()) await part.delete();
    } on Object {
      // Best effort: nothing else can be done about a file we cannot delete.
    }
  }

  DownloadException _fromFileSystem(FileSystemException e) {
    final code = e.osError?.errorCode;
    if (code == 28) {
      return const DownloadException(
        DownloadFailure.diskSpace,
        'The disk is full.',
      );
    }
    if (code == 13 || code == 1 || code == 30) {
      return const DownloadException(
        DownloadFailure.permission,
        'Notes is not allowed to write the update file.',
      );
    }
    return DownloadException(DownloadFailure.interrupted, e.message);
  }

  static String _mb(int bytes) => ((bytes + 1048575) ~/ 1048576).toString();
}

/// Deletes every leftover update file in [dir] except [keep]: partial
/// downloads and artifacts of older releases. Never touches other files.
Future<void> cleanUpdateDir(Directory dir, {String? keep}) async {
  if (!await dir.exists()) return;
  await for (final e in dir.list(followLinks: false)) {
    if (e is! File) continue;
    final name = e.uri.pathSegments.last;
    if (name == keep) continue;
    final ours =
        name.endsWith('.part') ||
        RegExp(r'^notes-.*\.(tar\.gz|apk)$').hasMatch(name);
    if (!ours) continue;
    try {
      await e.delete();
    } on Object {
      // Leave it; the next run tries again.
    }
  }
}
