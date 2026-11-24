import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/cloud/cloud_api.dart';

import '../../support/fake_cloud_server.dart';

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
