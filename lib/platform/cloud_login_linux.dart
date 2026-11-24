import 'dart:async';
import 'dart:io';

import 'cloud_login.dart';

typedef CloudProcessRunner = Future<void> Function(
  String executable,
  List<String> args,
);

Future<void> _runProcess(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) throw Exception('Could not open the browser');
}

class LinuxCloudLoginLauncher implements CloudLoginLauncher {
  LinuxCloudLoginLauncher({CloudProcessRunner? processRunner})
    : _processRunner = processRunner ?? _runProcess;

  final CloudProcessRunner _processRunner;
  HttpServer? _server;
  Completer<CloudLoginResult>? _pending;
  Timer? _timer;

  @override
  Future<CloudLoginResult> login(
    Uri Function(String redirect) startUrl, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (_pending != null) throw StateError('A cloud login is already active');
    final pending = Completer<CloudLoginResult>();
    _pending = pending;
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      final redirect = 'http://127.0.0.1:${server.port}/cb';
      server.listen(_handleRequest);
      _timer = Timer(timeout, () {
        _finishError(const CloudLoginTimeout());
      });
      await _processRunner('xdg-open', [startUrl(redirect).toString()]);
      return await pending.future;
    } catch (_) {
      if (!pending.isCompleted) {
        _finishError(Exception('Could not start cloud sign-in'));
      }
      return pending.future;
    }
  }

  void _handleRequest(HttpRequest request) {
    if (_pending == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
      return;
    }
    if (request.uri.path != '/cb') {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
      return;
    }
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      request.response.close();
      return;
    }
    final hostHeader = request.headers.value(HttpHeaders.hostHeader);
    final parsedHost = hostHeader == null
        ? null
        : Uri.tryParse('http://$hostHeader');
    if (parsedHost?.host != '127.0.0.1' ||
        !parsedHost!.hasPort ||
        parsedHost.port != _server!.port) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType.html;
    request.response.write(
      '<!doctype html><html><body>You can return to Notes.</body></html>',
    );
    request.response.close();
    try {
      _finish(parseCloudLoginRedirect(request.uri));
    } catch (error) {
      _finishError(error);
    }
  }

  void _finish(CloudLoginResult result) {
    final pending = _pending;
    if (pending == null) return;
    _cleanup();
    pending.complete(result);
  }

  void _finishError(Object error) {
    final pending = _pending;
    if (pending == null) return;
    _cleanup();
    pending.completeError(error);
  }

  void _cleanup() {
    _timer?.cancel();
    _timer = null;
    _server?.close();
    _server = null;
    _pending = null;
  }

  @override
  void cancel() {
    if (_pending != null) _finishError(const CloudLoginCancelled());
  }
}
