import 'dart:async';
import 'dart:typed_data';

import 'package:notes/update/update_http.dart';

/// One scripted answer.
class FakeReply {
  FakeReply(
    this.status, {
    this.body = const [],
    this.headers = const {},
    this.chunks,
    this.error,
    this.hang = false,
    this.streamError,
  });

  final int status;
  final List<int> body;
  final Map<String, String> headers;

  /// When set, the body is delivered in these chunks instead of [body].
  final List<List<int>>? chunks;

  /// Thrown from `get` (for example [UpdateOfflineException]).
  final Object? error;

  /// `get` never completes.
  final bool hang;

  /// Delivered after the chunks, as an error on the body stream.
  final Object? streamError;
}

/// A scripted [UpdateHttp]. Records every request. No test ever touches the
/// network.
class FakeHttp implements UpdateHttp {
  final routes = <String, List<FakeReply>>{};
  final requests = <({Uri url, Map<String, String> headers})>[];

  /// Answers [url] with [reply]; a list is consumed in order (the last one
  /// repeats).
  void on(String url, FakeReply reply) =>
      routes.putIfAbsent(url, () => []).add(reply);

  void replace(String url, FakeReply reply) => routes[url] = [reply];

  int count(String url) =>
      requests.where((r) => r.url.toString() == url).length;

  @override
  Future<UpdateResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    requests.add((url: url, headers: Map.of(headers)));
    final list = routes[url.toString()];
    if (list == null || list.isEmpty) {
      throw StateError('FakeHttp: unexpected request to $url');
    }
    final reply = list.length > 1 ? list.removeAt(0) : list.first;
    if (reply.hang) await Completer<void>().future;
    if (reply.error != null) throw reply.error!;
    final controller = StreamController<List<int>>();
    scheduleMicrotask(() async {
      for (final c in reply.chunks ?? [reply.body]) {
        if (controller.isClosed) return;
        if (c.isNotEmpty) controller.add(Uint8List.fromList(c));
        await Future<void>.delayed(Duration.zero);
      }
      if (reply.streamError != null && !controller.isClosed) {
        controller.addError(reply.streamError!);
      }
      if (!controller.isClosed) await controller.close();
    });
    return UpdateResponse(
      status: reply.status,
      headers: reply.headers,
      body: controller.stream,
    );
  }
}
