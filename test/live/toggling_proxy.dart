import 'dart:io';

/// A loopback HTTP proxy to the test Worker that can be switched "offline":
/// while offline it drops every connection without a response, which is what
/// a client sees when the network is gone. Used only by the latency test.
class TogglingProxy {
  TogglingProxy._(this._server, this._target, this._client);

  final HttpServer _server;
  final Uri _target;
  final HttpClient _client;
  bool online = true;

  /// Requests seen so far by path (without query), counted before forwarding.
  final counts = <String, int>{};

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<TogglingProxy> start(Uri target) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = TogglingProxy._(server, target, HttpClient());
    server.listen(proxy._handle);
    return proxy;
  }

  static const _skipped = {
    'host',
    'content-length',
    'connection',
    'accept-encoding',
    'transfer-encoding',
  };

  Future<void> _handle(HttpRequest request) async {
    counts.update(request.uri.path, (n) => n + 1, ifAbsent: () => 1);
    if (!online) {
      (await request.response.detachSocket(writeHeaders: false)).destroy();
      return;
    }
    try {
      final upstream = await _client.openUrl(
        request.method,
        _target.resolve(request.uri.toString()),
      );
      request.headers.forEach((name, values) {
        if (_skipped.contains(name)) return;
        for (final value in values) {
          upstream.headers.add(name, value);
        }
      });
      final body = <int>[];
      await for (final chunk in request) {
        body.addAll(chunk);
      }
      upstream.contentLength = body.length;
      upstream.add(body);
      final response = await upstream.close();
      request.response.statusCode = response.statusCode;
      for (final name in const [
        'content-type',
        'retry-after',
        'cache-control',
      ]) {
        final value = response.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      await request.response.addStream(response);
      await request.response.close();
    } on Object {
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } on Object {
        // The client already went away.
      }
    }
  }

  Future<void> close() async {
    _client.close(force: true);
    await _server.close(force: true);
  }
}
