import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/onboarding/onboarding_screen.dart';
import 'package:notes/ui/onboarding/welcome_points.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../../support/screenshot.dart';

Widget _host(AppSettings settings, Widget child, {double textScale = 1}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(settings),
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: c!,
    ),
    home: child,
  );
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('each action fires only its own callback', (tester) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 915));
    var create = 0, import = 0, skip = 0;
    await tester.pumpWidget(
      _host(
        services.settings,
        OnboardingScreen(
          onCreateNote: () => create++,
          onImport: () => import++,
          onSkip: () => skip++,
        ),
      ),
    );

    await tester.tap(find.text('Create a note'));
    expect((create, import, skip), (1, 0, 0));
    await tester.tap(find.text('Import notes'));
    expect((create, import, skip), (1, 1, 0));
    await tester.tap(find.text('Skip'));
    expect((create, import, skip), (1, 1, 1));
  });

  testWidgets('shows the five welcome points and the welcome heading', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 915));
    await tester.pumpWidget(
      _host(
        services.settings,
        OnboardingScreen(onCreateNote: () {}, onImport: () {}, onSkip: () {}),
      ),
    );

    expect(find.text('Welcome to Notes'), findsOneWidget);
    expect(welcomePoints, hasLength(5));
    for (final point in welcomePoints) {
      expect(find.text(point.title), findsOneWidget, reason: point.title);
    }
  });

  testWidgets('taking an action writes no settings and creates nothing', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 915));
    await tester.pumpWidget(
      _host(
        services.settings,
        OnboardingScreen(onCreateNote: () {}, onImport: () {}, onSkip: () {}),
      ),
    );
    final before = services.settings.theme;
    await tester.tap(find.text('Skip'));
    expect(services.settings.theme, before);
    expect(services.settings.onboardingPending, isFalse);
  });

  for (final size in const [Size(320, 640), Size(1280, 800)]) {
    for (final theme in AppTheme.values) {
      testWidgets(
        'no overflow at 1.4 text scale on ${size.width.toInt()} wide, '
        '${theme.name} theme',
        (tester) async {
          final services = AppServices.inMemory();
          addTearDown(services.close);
          await setWindow(tester, size);
          services.settings.theme = theme;
          await tester.pumpWidget(
            _host(
              services.settings,
              OnboardingScreen(
                onCreateNote: () {},
                onImport: () {},
                onSkip: () {},
              ),
              textScale: 1.4,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          for (final label in ['Create a note', 'Import notes', 'Skip']) {
            final button = find.ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            );
            expect(button, findsOneWidget, reason: label);
            expect(
              tester.getSize(button).height,
              greaterThanOrEqualTo(48),
              reason: '$label target',
            );
          }
        },
      );
    }
  }
}
