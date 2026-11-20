import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// The network is unreachable (no connection, DNS failure, refused).
class UpdateOfflineException implements Exception {
  const UpdateOfflineException([this.message = 'No network connection.']);
  final String message;

  @override
  String toString() => 'UpdateOfflineException: $message';
}

/// The server answered in a way the updater will not accept.
class UpdateProtocolException implements Exception {
  const UpdateProtocolException(this.message);
  final String message;

  @override
  String toString() => 'UpdateProtocolException: $message';
}

/// A response body went over its size cap.
class BodyTooLargeException implements Exception {
  const BodyTooLargeException(this.limit);
  final int limit;

  @override
  String toString() => 'BodyTooLargeException: more than $limit bytes';
}

/// One HTTP response. The body is a stream and must be consumed or [close]d.
class UpdateResponse {
  UpdateResponse({
    required this.status,
    required this.headers,
    required this.body,
    this.onClose,
  });

  final int status;

  /// Header names in lower case.
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final Future<void> Function()? onClose;

  Future<void> close() async => onClose?.call();
}

/// The only network surface of the updater. Production uses [IoUpdateHttp];
/// tests inject a fake so no test ever reaches the network.
///
/// Implementations must NOT follow redirects (the caller does, hop by hop,
/// with its own rules), must send only the given headers plus a generic
/// User-Agent, and must throw [UpdateOfflineException] when the network is
/// unreachable.
abstract class UpdateHttp {
  Future<UpdateResponse> get(Uri url, {Map<String, String> headers});
}

/// `dart:io` HttpClient implementation. HTTPS only; certificates are checked
/// by the platform (no override). A new client per request, closed with it.
class IoUpdateHttp implements UpdateHttp {
  IoUpdateHttp({
    this.connectTimeout = const Duration(seconds: 10),
    this.headerTimeout = const Duration(seconds: 25),
    this.userAgent = 'Notes-update-check',
  });

  final Duration connectTimeout;

  /// Longest wait for the response headers after the request is sent. A server
  /// that accepts the connection and never answers has its request aborted and
  /// the client closed, so repeated checks cannot pile up pending sockets.
  final Duration headerTimeout;
  final String userAgent;

  @override
  Future<UpdateResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    if (url.scheme != 'https') {
      throw const UpdateProtocolException('Only HTTPS is allowed.');
    }
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..userAgent = userAgent
      ..autoUncompress = true;
    try {
      final request = await client.getUrl(url);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final HttpClientResponse response;
      try {
        response = await request.close().timeout(headerTimeout);
      } on TimeoutException {
        request.abort();
        rethrow;
      }
      final out = <String, String>{};
      response.headers.forEach((name, values) {
        out[name.toLowerCase()] = values.join(', ');
      });
      return UpdateResponse(
        status: response.statusCode,
        headers: out,
        body: response,
        onClose: () async => client.close(force: true),
      );
    } on SocketException catch (e) {
      client.close(force: true);
      throw UpdateOfflineException(e.message);
    } on HandshakeException {
      client.close(force: true);
      throw const UpdateProtocolException('Secure connection failed.');
    } on TimeoutException {
      client.close(force: true);
      throw const UpdateOfflineException('Connection timed out.');
    } on HttpException catch (e) {
      client.close(force: true);
      throw UpdateProtocolException(e.message);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}

/// Follows redirects by hand: at most [maxHops], every hop must be https.
/// Relative `Location` values resolve against the current URL. Intermediate
/// responses are closed. The returned response's body is not consumed.
Future<UpdateResponse> getFollowingRedirects(
  UpdateHttp http,
  Uri url, {
  Map<String, String> headers = const {},
  int maxHops = 5,
}) async {
  var current = url;
  for (var hop = 0; hop <= maxHops; hop++) {
    if (current.scheme != 'https') {
      throw const UpdateProtocolException('Only HTTPS is allowed.');
    }
    final response = await http.get(current, headers: headers);
    final redirect = const {301, 302, 303, 307, 308}.contains(response.status);
    if (!redirect) return response;
    final location = response.headers['location'];
    await response.close();
    if (location == null || location.isEmpty) {
      throw const UpdateProtocolException('Redirect without a location.');
    }
    final next = Uri.tryParse(location);
    if (next == null) {
      throw const UpdateProtocolException('Invalid redirect location.');
    }
    current = current.resolveUri(next);
  }
  throw const UpdateProtocolException('Too many redirects.');
}

/// Reads a body, aborting as soon as it exceeds [maxBytes] or stalls longer
/// than [timeout] overall.
Future<Uint8List> readBodyCapped(
  UpdateResponse response, {
  required int maxBytes,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final declared = int.tryParse(response.headers['content-length'] ?? '');
  if (declared != null && declared > maxBytes) {
    await response.close();
    throw BodyTooLargeException(maxBytes);
  }
  final builder = BytesBuilder(copy: false);
  final done = Completer<Uint8List>();
  late final StreamSubscription<List<int>> sub;
  sub = response.body.listen(
    (chunk) {
      builder.add(chunk);
      if (builder.length > maxBytes && !done.isCompleted) {
        sub.cancel();
        done.completeError(BodyTooLargeException(maxBytes));
      }
    },
    onError: (Object e, StackTrace s) {
      if (!done.isCompleted) done.completeError(e, s);
    },
    onDone: () {
      if (!done.isCompleted) done.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  try {
    return await done.future.timeout(timeout);
  } on TimeoutException {
    await sub.cancel();
    rethrow;
  } finally {
    await response.close();
  }
}
