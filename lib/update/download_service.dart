import 'dart:async';
import 'dart:convert';
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
final _contentRange = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');

/// Streams an update artifact to disk and proves it is the one the signed
/// manifest described. Interrupted transfers keep a scoped `.part` file and
/// metadata so the next attempt can safely use HTTP Range. The whole file is
/// hashed before the same-directory rename publishes it as complete.
class DownloadService {
  DownloadService(
    this._http, {
    this.freeSpace,
    this.idleTimeout = const Duration(seconds: 30),
    this.headerTimeout = const Duration(seconds: 30),
    this.totalDeadline = const Duration(minutes: 45),
    this.spaceMargin = 16 * 1024 * 1024,
  });

  final UpdateHttp _http;
  final FreeSpaceProbe? freeSpace;

  /// Longest wait for the next chunk.
  final Duration idleTimeout;

  /// Longest the whole transfer may take, so a server that trickles a few
  /// bytes just often enough to dodge [idleTimeout] cannot hold it forever.
  final Duration totalDeadline;

  /// Longest wait for the server's response headers (and redirects).
  final Duration headerTimeout;

  /// Extra free space required beyond the remaining artifact bytes.
  final int spaceMargin;

  Future<File> download({
    required Uri url,
    required Directory dir,
    required String filename,
    required String sha256Hex,
    required int size,
    String releaseVersion = '',
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
    final metadata = File('${dir.path}/$filename.part.json');
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

      final resume = await _matchingPartial(
        part,
        metadata,
        url: url,
        filename: filename,
        releaseVersion: releaseVersion,
        size: size,
        sha256Hex: sha256Hex,
      );
      var offset = resume == null ? 0 : await part.length();
      if (offset > size) {
        await _discard(part);
        await _discard(metadata);
        offset = 0;
      }
      // A complete .part can be left by cancellation just before rename.
      if (offset == size && await _matches(part, size, sha256Hex)) {
        await part.rename(finalFile.path);
        await _discard(metadata);
        onProgress?.call(size, size);
        return finalFile;
      }
      if (offset == size) {
        await _discard(part);
        await _discard(metadata);
        offset = 0;
      }

      final free = await freeSpace?.call(dir.path);
      final required = size - offset + spaceMargin;
      if (free != null && free < required) {
        throw DownloadException(
          DownloadFailure.diskSpace,
          'Not enough free space: about ${_mb(required)} MB is needed.',
        );
      }
      if (token.isCancelled) throw _cancelled;

      final nextMetadata = _ResumeMetadata(
        url: url.toString(),
        filename: filename,
        releaseVersion: releaseVersion,
        size: size,
        sha256Hex: sha256Hex,
        etag: resume?.etag,
      );
      await _writeMetadata(metadata, nextMetadata);
      if (offset > 0) onProgress?.call(offset, size);
      await _stream(
        url: url,
        part: part,
        metadataFile: metadata,
        metadata: nextMetadata,
        offset: offset,
        size: size,
        onProgress: onProgress,
        token: token,
        allowRestart: true,
      );

      if (!await _matches(part, size, sha256Hex)) {
        await _discard(part);
        await _discard(metadata);
        throw const DownloadException(
          DownloadFailure.checksumMismatch,
          'The downloaded file does not match its checksum.',
        );
      }
      await part.rename(finalFile.path);
      await _discard(metadata);
      return finalFile;
    } on FileSystemException catch (e) {
      final failure = _fromFileSystem(e);
      if (!await _preservePartial(failure.kind, part)) {
        await _discard(part);
        await _discard(metadata);
      }
      throw failure;
    } on DownloadException catch (e) {
      if (!await _preservePartial(e.kind, part)) {
        await _discard(part);
        await _discard(metadata);
      }
      rethrow;
    } catch (_) {
      // Unexpected protocol or programming errors must not leave an unscoped
      // partial that could be resumed as if it were trusted.
      await _discard(part);
      await _discard(metadata);
      rethrow;
    }
  }

  static const _cancelled = DownloadException(
    DownloadFailure.cancelled,
    'The download was cancelled. You can resume it later.',
  );

  bool _keepPartial(DownloadFailure failure) => switch (failure) {
    DownloadFailure.cancelled ||
    DownloadFailure.offline ||
    DownloadFailure.interrupted ||
    DownloadFailure.diskSpace => true,
    _ => false,
  };

  Future<bool> _preservePartial(DownloadFailure failure, File part) async {
    if (!_keepPartial(failure)) return false;
    try {
      return await part.exists() && await part.length() > 0;
    } on Object {
      return false;
    }
  }

  Future<_ResumeMetadata?> _matchingPartial(
    File part,
    File metadataFile, {
    required Uri url,
    required String filename,
    required String releaseVersion,
    required int size,
    required String sha256Hex,
  }) async {
    if (!await part.exists() || !await metadataFile.exists()) {
      await _discard(part);
      await _discard(metadataFile);
      return null;
    }
    try {
      final decoded = jsonDecode(await metadataFile.readAsString());
      final metadata = _ResumeMetadata.fromJson(decoded);
      if (metadata.url != url.toString() ||
          metadata.filename != filename ||
          metadata.releaseVersion != releaseVersion ||
          metadata.size != size ||
          metadata.sha256Hex != sha256Hex) {
        await _discard(part);
        await _discard(metadataFile);
        return null;
      }
      if (!_isStrongEtag(metadata.etag)) {
        // A partial without a strong validator cannot safely be resumed.
        await _discard(part);
        await _discard(metadataFile);
        return null;
      }
      return metadata;
    } on Object {
      await _discard(part);
      await _discard(metadataFile);
      return null;
    }
  }

  Future<void> _stream({
    required Uri url,
    required File part,
    required File metadataFile,
    required _ResumeMetadata metadata,
    required int offset,
    required int size,
    required void Function(int, int)? onProgress,
    required CancelToken token,
    required bool allowRestart,
  }) async {
    final headers = <String, String>{'Accept-Encoding': 'identity'};
    if (offset > 0) {
      final etag = metadata.etag;
      if (!_isStrongEtag(etag)) {
        throw StateError('A partial update needs a strong ETag to resume.');
      }
      headers['Range'] = 'bytes=$offset-';
      headers['If-Range'] = etag!;
    }
    final response = await _open(url, headers, token);
    var append = false;
    if (response.status == 206) {
      final range = _contentRange.firstMatch(
        response.headers['content-range'] ?? '',
      );
      final start = int.tryParse(range?.group(1) ?? '');
      final end = int.tryParse(range?.group(2) ?? '');
      final total = int.tryParse(range?.group(3) ?? '');
      final etag = response.headers['etag'];
      final validRange =
          offset > 0 && start == offset && end == size - 1 && total == size;
      final validEtag = _isStrongEtag(metadata.etag) && etag == metadata.etag;
      if (!validRange || !validEtag) {
        await response.close();
        if (!allowRestart) {
          throw const DownloadException(
            DownloadFailure.http,
            'The server returned an invalid partial update response.',
          );
        }
        await _discard(part);
        await _discard(metadataFile);
        final fresh = metadata.copyWith(etag: null);
        await _writeMetadata(metadataFile, fresh);
        return _stream(
          url: url,
          part: part,
          metadataFile: metadataFile,
          metadata: fresh,
          offset: 0,
          size: size,
          onProgress: onProgress,
          token: token,
          allowRestart: false,
        );
      }
      append = true;
      metadata = metadata.copyWith(etag: etag);
    } else if (response.status == 200) {
      // A server that ignores Range (or rejects If-Range) returns the whole
      // representation. Treat it as a fresh transfer from byte zero.
      offset = 0;
      metadata = metadata.copyWith(etag: response.headers['etag']);
    } else {
      await response.close();
      throw DownloadException(
        DownloadFailure.http,
        'The server answered with status ${response.status}.',
      );
    }

    await _writeMetadata(metadataFile, metadata);
    final expectedLength = size - offset;
    final type = (response.headers['content-type'] ?? '').toLowerCase();
    if (type.contains('text/html') || type.contains('json')) {
      await response.close();
      throw const DownloadException(
        DownloadFailure.contentType,
        'The server sent a web page instead of the update file.',
      );
    }
    final declared = int.tryParse(response.headers['content-length'] ?? '');
    if (declared != null &&
        !response.headers.containsKey('content-encoding') &&
        declared != expectedLength) {
      await response.close();
      throw const DownloadException(
        DownloadFailure.sizeMismatch,
        'The file is not the size the release declares.',
      );
    }

    token._onCancel(() => unawaited(response.close()));
    IOSink? sink;
    try {
      sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      var received = offset;
      final clock = Stopwatch()..start();
      try {
        await for (final chunk in response.body.timeout(idleTimeout)) {
          if (token.isCancelled) throw _cancelled;
          if (clock.elapsed > totalDeadline) {
            throw const DownloadException(
              DownloadFailure.interrupted,
              'The download took too long.',
            );
          }
          received += chunk.length;
          if (received > size) {
            throw const DownloadException(
              DownloadFailure.sizeMismatch,
              'The file is larger than the release declares.',
            );
          }
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
      if (received != size) {
        throw const DownloadException(
          DownloadFailure.interrupted,
          'The download ended early.',
        );
      }
    } finally {
      try {
        await sink?.close();
      } on Object {
        // The write already failed; the caller keeps only a scoped partial.
      }
      await response.close();
    }
  }

  bool _isStrongEtag(String? etag) {
    if (etag == null ||
        etag.length < 2 ||
        !etag.startsWith('"') ||
        !etag.endsWith('"') ||
        etag.startsWith('W/')) {
      return false;
    }
    for (var i = 1; i < etag.length - 1; i++) {
      final char = etag.codeUnitAt(i);
      if (char < 0x21 || char == 0x22 || char == 0x7f || char > 0xff) {
        return false;
      }
    }
    return true;
  }

  Future<UpdateResponse> _open(
    Uri url,
    Map<String, String> headers,
    CancelToken token,
  ) async {
    final cancelled = Completer<UpdateResponse>();
    token._onCancel(() {
      if (!cancelled.isCompleted) cancelled.completeError(_cancelled);
    });
    final pending = getFollowingRedirects(_http, url, headers: headers);
    try {
      return await Future.any([pending, cancelled.future])
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
  }

  Future<bool> _matches(File f, int size, String sha256Hex) async {
    if (!await f.exists() || await f.length() != size) return false;
    final d = await sha256.bind(f.openRead()).first;
    return d.toString() == sha256Hex;
  }

  Future<void> _writeMetadata(File file, _ResumeMetadata metadata) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(metadata.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
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

class _ResumeMetadata {
  const _ResumeMetadata({
    required this.url,
    required this.filename,
    required this.releaseVersion,
    required this.size,
    required this.sha256Hex,
    required this.etag,
  });

  final String url;
  final String filename;
  final String releaseVersion;
  final int size;
  final String sha256Hex;
  final String? etag;

  _ResumeMetadata copyWith({String? etag}) => _ResumeMetadata(
    url: url,
    filename: filename,
    releaseVersion: releaseVersion,
    size: size,
    sha256Hex: sha256Hex,
    etag: etag,
  );

  Map<String, Object?> toJson() => {
    'url': url,
    'filename': filename,
    'releaseVersion': releaseVersion,
    'size': size,
    'sha256': sha256Hex,
    'etag': etag,
  };

  static _ResumeMetadata fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['url'] is! String ||
        value['filename'] is! String ||
        value['releaseVersion'] is! String ||
        value['size'] is! int ||
        value['sha256'] is! String ||
        (value['etag'] != null && value['etag'] is! String)) {
      throw const FormatException('Invalid resume metadata.');
    }
    return _ResumeMetadata(
      url: value['url'] as String,
      filename: value['filename'] as String,
      releaseVersion: value['releaseVersion'] as String,
      size: value['size'] as int,
      sha256Hex: value['sha256'] as String,
      etag: value['etag'] as String?,
    );
  }
}

/// Deletes every leftover update file in [dir] except [keep]: partial
/// downloads and artifacts of older releases. Never touches other files.
Future<void> cleanUpdateDir(
  Directory dir, {
  String? keep,
  String? keepPartialFor,
}) async {
  if (!await dir.exists()) return;
  await for (final e in dir.list(followLinks: false)) {
    if (e is! File) continue;
    final name = e.uri.pathSegments.last;
    if (name == keep) continue;
    if (keepPartialFor != null &&
        (name == '$keepPartialFor.part' ||
            name == '$keepPartialFor.part.json')) {
      continue;
    }
    final ours =
        name.endsWith('.part') ||
        name.endsWith('.part.json') ||
        name.endsWith('.part.json.tmp') ||
        RegExp(r'^notes-.*\.(tar\.gz|apk)$').hasMatch(name);
    if (!ours) continue;
    try {
      await e.delete();
    } on Object {
      // Leave it; the next run tries again.
    }
  }
}
