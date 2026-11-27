import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../support/screenshot.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('app starts on the library and follows theme settings', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 915));
    await pumpApp(tester, services);
    BuildContext ctx() => tester.element(find.text('All notes'));
    expect(AppPalette.of(ctx()).background, AppPalette.amoled.background);
    services.settings.theme = AppTheme.light;
    await tester.pumpAndSettle();
    expect(AppPalette.of(ctx()).background, AppPalette.light.background);
    services.settings.animations = AnimationLevel.off;
    await tester.pumpAndSettle();
    expect(AppMotion.of(ctx()).page, Duration.zero);
    await screenshot(tester, 'shell');
  });

  test('settings persist across reopen and ignore bad stored values', () {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    final s = services.settings;
    s.layout = LibraryLayout.list;
    s.textScale = 9;
    s.toolbar = [ToolbarItem.bold, ToolbarItem.link];
    services.db.execute("INSERT INTO settings VALUES ('theme', 'neon')");
    final again = AppSettings(services.db);
    expect(again.layout, LibraryLayout.list);
    expect(again.textScale, 1.4);
    expect(again.toolbar, [ToolbarItem.bold, ToolbarItem.link]);
    expect(again.theme, AppTheme.amoled);
    again.dispose();
  });

  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    for (final theme in AppTheme.values) {
      testWidgets('system reduced motion overrides $theme at $size', (
        tester,
      ) async {
        final services = AppServices.inMemory();
        addTearDown(services.close);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        services.settings.theme = theme;
        services.settings.textScale = 1.4;
        await setWindow(tester, size);
        await pumpApp(tester, services);
        BuildContext ctx() => tester.element(find.text('All notes').first);
        expect(AppMotion.of(ctx()).medium, const Duration(milliseconds: 220));

        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        await tester.pumpAndSettle();
        expect(AppMotion.of(ctx()).fast, Duration.zero);
        expect(AppMotion.of(ctx()).medium, Duration.zero);
        expect(AppMotion.of(ctx()).page, Duration.zero);
        expect(Theme.of(ctx()).splashFactory, NoSplash.splashFactory);
        const page = SizedBox();
        for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
          final transitions = Theme.of(ctx())
              .pageTransitionsTheme
              .builders[platform]!;
          expect(
            transitions.buildTransitions<void>(
              MaterialPageRoute<void>(builder: (_) => page),
              ctx(),
              kAlwaysCompleteAnimation,
              kAlwaysDismissedAnimation,
              page,
            ),
            same(page),
          );
        }
        expect(
          tester
              .widget<MaterialApp>(find.byType(MaterialApp))
              .themeAnimationDuration,
          Duration.zero,
        );
        // The system preference is device state, never a stored settings edit.
        expect(services.settings.animations, AnimationLevel.full);

        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures();
        await tester.pumpAndSettle();
        expect(AppMotion.of(ctx()).medium, const Duration(milliseconds: 220));
        services.settings.animations = AnimationLevel.reduced;
        await tester.pumpAndSettle();
        expect(AppMotion.of(ctx()).medium, const Duration(milliseconds: 110));
        services.settings.animations = AnimationLevel.off;
        await tester.pumpAndSettle();
        expect(AppMotion.of(ctx()).medium, Duration.zero);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
