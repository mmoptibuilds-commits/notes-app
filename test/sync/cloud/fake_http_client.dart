import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef FakeHttpHandler = ({int status, String body}) Function(
  String method,
  Uri uri,
);

class ScriptedHttpClient implements HttpClient {
  ScriptedHttpClient(this.handler);
  final FakeHttpHandler handler;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _Request(method, url, handler);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.method, this.uri, this.handler);
  @override
  final String method;
  @override
  final Uri uri;
  final FakeHttpHandler handler;
  final _Headers requestHeaders = _Headers();
  final _body = BytesBuilder();
  @override
  HttpHeaders get headers => requestHeaders;
  @override
  bool followRedirects = true;
  @override
  void write(Object? object) => _body.add(utf8.encode('$object'));
  @override
  Future<HttpClientResponse> close() async {
    final reply = handler(method, uri);
    return _Response(reply.status, utf8.encode(reply.body));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, List<int> body) : _body = _closedBody(body);
  final Stream<List<int>> _body;
  @override
  final int statusCode;
  @override
  int get contentLength => -1;
  @override
  HttpHeaders get headers => _Headers(contentType: ContentType.json);
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Stream<List<int>> _closedBody(List<int> body) {
  final controller = StreamController<List<int>>(sync: true);
  controller
    ..add(Uint8List.fromList(body))
    ..close();
  return controller.stream;
}

class _Headers implements HttpHeaders {
  _Headers({this.contentType}) {
    if (contentType != null) {
      _values[HttpHeaders.contentTypeHeader] = [contentType!.mimeType];
    }
  }
  @override
  ContentType? contentType;
  final _values = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = ['$value'];
  }

  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(', ');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
