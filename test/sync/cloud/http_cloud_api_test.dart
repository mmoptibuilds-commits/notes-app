import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/cloud/cloud_api.dart';

import '../../support/fake_cloud_server.dart';
import 'fake_http_client.dart';

void main() {
  test(
    'HTTP client talks to a loopback server and sends the stored bearer',
    () async {
      final server = FakeCloudServer();
      final url = await server.startHttpServer();
      addTearDown(server.closeHttpServer);
      final sessions = MemoryCloudSessionStore()
        ..session = const CloudSession(
          deviceId: 'test-device',
          access: 'test-access',
          accessExp: 9999999999,
          refresh: 'test-refresh',
        );
      final api = HttpCloudApi(baseUrl: url, sessions: sessions);
      addTearDown(api.close);
      expect((await api.health())['ok'], isTrue);
      expect((await api.head())['libraryId'], 'test-library');
    },
  );

  test('an authenticated POST with a body carries its bearer header', () async {
    // Regression: the authorization header used to be set after the body was
    // written, which fails with "HTTP headers are not mutable" on a real server.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? seenAuth;
    String? seenBody;
    server.listen((request) async {
      seenAuth = request.headers.value(HttpHeaders.authorizationHeader);
      seenBody = await utf8.decoder.bind(request).join();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true}));
      await request.response.close();
    });
    final sessions = MemoryCloudSessionStore()
      ..session = const CloudSession(
        deviceId: 'test-device',
        access: 'test-access',
        accessExp: 9999999999,
        refresh: 'test-refresh',
      );
    final api = HttpCloudApi(
      baseUrl: Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
      sessions: sessions,
    );
    addTearDown(api.close);
    await api.logout();
    expect(seenAuth, 'Bearer test-access');
    expect(seenBody, isNotEmpty);
  });

  test(
    'an empty library response is not found only on GET /v1/library',
    () async {
      const workerBody = '{"error":"library","message":"No library"}';

      HttpCloudApi apiFor(int status, String body, {bool signedIn = true}) {
        final sessions = MemoryCloudSessionStore();
        if (signedIn) {
          sessions.session = const CloudSession(
            deviceId: 'test-device',
            access: 'test-access',
            accessExp: 9999999999,
            refresh: 'test-refresh',
          );
        }
        final api = HttpCloudApi(
          baseUrl: Uri.parse('https://worker.example.invalid'),
          sessions: sessions,
          client: ScriptedHttpClient(
            (method, uri) => (status: status, body: body),
          ),
        );
        addTearDown(api.close);
        return api;
      }

      final empty = apiFor(404, workerBody);
      await expectLater(
        empty.library(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.notFound,
          ),
        ),
      );

      final otherEndpoint = apiFor(404, workerBody);
      await expectLater(
        otherEndpoint.push('library-id', 'batch-id', const []),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.libraryMismatch,
          ),
        ),
      );

      final wrongLibrary = apiFor(409, '{"error":"library"}');
      await expectLater(
        wrongLibrary.library(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.libraryMismatch,
          ),
        ),
      );

      final unauthorized = apiFor(401, '{"error":"auth"}', signedIn: false);
      await expectLater(
        unauthorized.library(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.unauthorized,
          ),
        ),
      );

      final serverFailure = apiFor(500, '{"error":"internal"}');
      await expectLater(
        serverFailure.library(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.server,
          ),
        ),
      );

      final malformed = apiFor(400, 'not-json');
      await expectLater(
        malformed.library(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.malformed,
          ),
        ),
      );

      final offline = HttpCloudApi(
        baseUrl: Uri.parse('https://worker.example.invalid'),
        sessions: MemoryCloudSessionStore(),
        timeout: const Duration(milliseconds: 100),
        client: ScriptedHttpClient(
          (method, uri) => throw const SocketException('offline'),
        ),
      );
      addTearDown(offline.close);
      await expectLater(
        offline.library(),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.network,
          ),
        ),
      );
    },
  );

  test(
    'refresh retains credentials for retryable errors and clears only auth',
    () async {
      final server = FakeCloudServer();
      final url = await server.startHttpServer();
      addTearDown(server.closeHttpServer);
      const session = CloudSession(
        deviceId: 'test-device',
        access: 'old-access',
        accessExp: 1,
        refresh: 'opaque-refresh-token',
      );
      final store = MemoryCloudSessionStore()..session = session;
      final api = HttpCloudApi(baseUrl: url, sessions: store);
      addTearDown(api.close);
      for (final kind in [CloudErrorKind.server, CloudErrorKind.rateLimited]) {
        server.refreshFailure = kind;
        server.refreshRetryAfter = const Duration(seconds: 47);
        await expectLater(
          api.refresh(session),
          throwsA(
            isA<CloudApiException>().having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 47),
            ),
          ),
        );
        expect(await store.read(), same(session));
      }
      server.responseDelay = const Duration(milliseconds: 100);
      final slowApi = HttpCloudApi(
        baseUrl: url,
        sessions: store,
        timeout: const Duration(milliseconds: 10),
      );
      addTearDown(slowApi.close);
      await expectLater(
        slowApi.refresh(session),
        throwsA(isA<CloudApiException>()),
      );
      expect(await store.read(), same(session));
      final offlineApi = HttpCloudApi(
        baseUrl: Uri.parse('http://127.0.0.1:1'),
        sessions: store,
        timeout: const Duration(milliseconds: 100),
      );
      addTearDown(offlineApi.close);
      await expectLater(
        offlineApi.refresh(session),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.network,
          ),
        ),
      );
      expect(await store.read(), same(session));
      server.responseDelay = Duration.zero;
      server.refreshFailure = CloudErrorKind.unauthorized;
      server.refreshError = 'other';
      await expectLater(
        api.refresh(session),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.malformed,
          ),
        ),
      );
      expect(await store.read(), same(session));
      server.refreshError = 'auth';
      await expectLater(
        api.refresh(session),
        throwsA(
          isA<CloudApiException>().having(
            (e) => e.kind,
            'kind',
            CloudErrorKind.unauthorized,
          ),
        ),
      );
      expect(await store.read(), isNull);
    },
  );
}
