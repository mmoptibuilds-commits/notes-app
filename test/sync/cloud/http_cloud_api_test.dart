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
}
