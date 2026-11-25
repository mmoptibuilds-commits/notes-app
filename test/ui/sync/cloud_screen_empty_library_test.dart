import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/sync/cloud_screen.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../../sync/cloud/fake_http_client.dart';

void main() {
  Future<void> pumpCloudScreen(
    WidgetTester tester,
    AppServices services,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 850);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          theme: buildTheme(services.settings),
          home: const CloudScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<(AppServices, HttpCloudApi)> setup(int libraryStatus) async {
    final base = AppServices.inMemory();
    final sessions = MemoryCloudSessionStore()
      ..session = const CloudSession(
        deviceId: 'test-device',
        access: 'test-access',
        accessExp: 9999999999,
        refresh: 'test-refresh',
      );
    final api = HttpCloudApi(
      baseUrl: Uri.parse('https://worker.example.invalid'),
      sessions: sessions,
      client: ScriptedHttpClient((method, uri) {
        if (uri.path == '/v1/library') {
          return (
            status: libraryStatus,
            body: libraryStatus == 404
                ? '{"error":"library","message":"No library"}'
                : '{"error":"internal"}',
          );
        }
        if (uri.path == '/v1/devices') {
          return (status: 200, body: '{"devices":[]}');
        }
        return (status: 404, body: '{}');
      }),
    );
    final cloud = CloudService(
      repo: base.notes,
      api: api,
      sessions: sessions,
      dataDir: '',
      deviceName: 'Test device',
      loginLauncher: null,
      unavailable: false,
      platformIsAndroid: () => false,
    );
    await cloud.restoreState();
    await cloud.setEnabled(true);
    return (
      AppServices(base.db, base.notes, base.settings, '', cloud: cloud),
      api,
    );
  }

  testWidgets('empty cloud library shows first-upload setup', (tester) async {
    final (services, api) = await setup(404);
    addTearDown(services.close);
    addTearDown(api.close);
    await pumpCloudScreen(tester, services);
    expect(find.text('Upload this library'), findsNWidgets(2));
    expect(find.text('Create verified backup'), findsOneWidget);
    expect(find.text('Could not check the cloud library.'), findsNothing);
  });

  testWidgets('cloud library server error keeps the error card', (
    tester,
  ) async {
    final (services, api) = await setup(500);
    addTearDown(services.close);
    addTearDown(api.close);
    await pumpCloudScreen(tester, services);
    expect(find.text('Could not check the cloud library.'), findsOneWidget);
    expect(find.text('Upload this library'), findsNothing);
  });
}
