import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/update/update_http.dart';

import 'fake_http.dart';

void main() {
  group('getFollowingRedirects', () {
    test('follows relative and absolute https redirects', () async {
      final http = FakeHttp()
        ..on(
          'https://a.example/start',
          FakeReply(302, headers: {'location': '/next'}),
        )
        ..on(
          'https://a.example/next',
          FakeReply(302, headers: {'location': 'https://cdn.example/f'}),
        )
        ..on('https://cdn.example/f', FakeReply(200, body: utf8.encode('ok')));
      final r = await getFollowingRedirects(
        http,
        Uri.parse('https://a.example/start'),
      );
      expect(r.status, 200);
      expect(http.requests, hasLength(3));
    });

    test('refuses a hop that is not https', () async {
      final http = FakeHttp()
        ..on(
          'https://a.example/start',
          FakeReply(302, headers: {'location': 'http://a.example/x'}),
        );
      await expectLater(
        getFollowingRedirects(http, Uri.parse('https://a.example/start')),
        throwsA(isA<UpdateProtocolException>()),
      );
    });

    test('refuses a first URL that is not https', () async {
      await expectLater(
        getFollowingRedirects(FakeHttp(), Uri.parse('http://a.example/')),
        throwsA(isA<UpdateProtocolException>()),
      );
    });

    test('caps the number of hops at five', () async {
      final http = FakeHttp()
        ..on(
          'https://a.example/loop',
          FakeReply(302, headers: {'location': '/loop'}),
        );
      await expectLater(
        getFollowingRedirects(http, Uri.parse('https://a.example/loop')),
        throwsA(isA<UpdateProtocolException>()),
      );
      expect(http.requests, hasLength(6)); // first request plus five hops
    });

    test('a redirect without a location fails', () async {
      final http = FakeHttp()..on('https://a.example/x', FakeReply(302));
      await expectLater(
        getFollowingRedirects(http, Uri.parse('https://a.example/x')),
        throwsA(isA<UpdateProtocolException>()),
      );
    });

    test('the same headers are sent on every hop', () async {
      final http = FakeHttp()
        ..on(
          'https://a.example/x',
          FakeReply(307, headers: {'location': 'https://b.example/y'}),
        )
        ..on('https://b.example/y', FakeReply(200));
      await getFollowingRedirects(
        http,
        Uri.parse('https://a.example/x'),
        headers: {'Accept': 'a'},
      );
      expect(http.requests.every((r) => r.headers['Accept'] == 'a'), isTrue);
    });
  });

  group('readBodyCapped', () {
    test('returns the bytes under the cap', () async {
      final http = FakeHttp()
        ..on('https://a.example/x', FakeReply(200, body: [1, 2, 3]));
      final r = await http.get(Uri.parse('https://a.example/x'));
      expect(await readBodyCapped(r, maxBytes: 10), [1, 2, 3]);
    });

    test('aborts when the cap is exceeded mid-stream', () async {
      final http = FakeHttp()
        ..on(
          'https://a.example/x',
          FakeReply(200, chunks: [List.filled(6, 1), List.filled(6, 1)]),
        );
      final r = await http.get(Uri.parse('https://a.example/x'));
      await expectLater(
        readBodyCapped(r, maxBytes: 10),
        throwsA(isA<BodyTooLargeException>()),
      );
    });
  });

  test('the real client refuses plain http without touching the network', () {
    expect(
      IoUpdateHttp().get(Uri.parse('http://example.invalid/')),
      throwsA(isA<UpdateProtocolException>()),
    );
  });

  test('HTTP errors use a retry message without raw exception details', () {
    return HttpOverrides.runZoned(() async {
      await expectLater(
        IoUpdateHttp().get(Uri.parse('https://example.invalid/')),
        throwsA(
          isA<UpdateProtocolException>().having(
            (failure) => failure.message,
            'message',
            allOf(
              contains('invalid HTTP response'),
              contains('Try again'),
              isNot(contains('synthetic internal detail')),
            ),
          ),
        ),
      );
    }, createHttpClient: (_) => _BrokenHttpClient());
  });
}

class _BrokenHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  String? userAgent;

  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      throw const HttpException('synthetic internal detail');

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
