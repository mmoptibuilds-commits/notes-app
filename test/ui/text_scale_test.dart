import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_screen.dart';

import '../support/screenshot.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('combines system and app text scales', (tester) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 915));

    for (final systemScale in [1.0, 1.3, 2.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = systemScale;
      for (final appScale in [1.0, 1.4]) {
        services.settings.textScale = appScale;
        await pumpApp(tester, services);
        final context = tester.element(find.text('All notes'));
        final scaler = MediaQuery.textScalerOf(context);
        expect(scaler.scale(20), closeTo(20 * systemScale * appScale, 0.001));
      }
    }
  });

  for (final size in [const Size(360, 800), const Size(412, 915)]) {
    testWidgets('library and editor remain usable at large scale on $size', (
      tester,
    ) async {
      final services = AppServices.inMemory();
      addTearDown(services.close);
      services.settings.textScale = 1.4;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await setWindow(tester, size);
      await pumpApp(tester, services);
      expect(find.byTooltip('New note'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('New note'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
      expect(find.byTooltip('More'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
