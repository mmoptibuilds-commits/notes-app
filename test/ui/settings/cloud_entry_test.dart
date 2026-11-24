import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/settings/sync_data_section.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../sync/support.dart';

void main() {
  testWidgets('cloud entry is hidden when cloud is unavailable', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          theme: buildTheme(services.settings),
          home: const Scaffold(body: SyncDataSection()),
        ),
      ),
    );
    expect(find.text('Cloud sync'), findsNothing);
  });

  testWidgets('cloud entry appears when the service is available', (
    tester,
  ) async {
    final services = servicesWithCloud();
    addTearDown(services.close);
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          theme: buildTheme(services.settings),
          home: const Scaffold(body: SyncDataSection()),
        ),
      ),
    );
    expect(find.text('Cloud sync'), findsOneWidget);
  });
}
