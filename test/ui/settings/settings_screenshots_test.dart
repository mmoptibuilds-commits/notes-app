import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';

import '../../support/screenshot.dart';
import '../library/support.dart';

/// Review artefacts in build/screens/.
void main() {
  setUpAll(loadAppFonts);

  Future<AppServices> open(WidgetTester tester, Size size) async {
    final base = AppServices.inMemory();
    final services = AppServices(
      base.db,
      base.notes,
      base.settings,
      '/home/user/.local/share/com.mmoptibuilds.notes',
    );
    addTearDown(services.close);
    await setWindow(tester, size);
    await pumpApp(tester, services);
    await menuTap(tester, 'Settings');
    return services;
  }

  testWidgets('settings phone', (tester) async {
    await open(tester, const Size(412, 915));
    await screenshot(tester, 'settings_phone');
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    await screenshot(tester, 'settings_phone_2');
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    await screenshot(tester, 'settings_phone_3');
  });

  testWidgets('settings phone light', (tester) async {
    final s = await open(tester, const Size(412, 915));
    s.settings.theme = AppTheme.light;
    await tester.pumpAndSettle();
    await screenshot(tester, 'settings_phone_light');
  });

  testWidgets('settings desktop', (tester) async {
    await open(tester, const Size(1280, 1500));
    await screenshot(tester, 'settings_desktop');
  });

  testWidgets('toolbar customisation', (tester) async {
    await open(tester, const Size(412, 915));
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customise toolbar'));
    await tester.pumpAndSettle();
    await screenshot(tester, 'settings_toolbar_phone');
  });

  testWidgets('toolbar customisation desktop', (tester) async {
    await open(tester, const Size(1280, 1500));
    await tester.tap(find.text('Customise toolbar'));
    await tester.pumpAndSettle();
    await screenshot(tester, 'settings_toolbar_desktop');
  });
}
