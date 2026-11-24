import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/data/data_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/theme/app_theme.dart';
import 'package:notes/ui/updates/update_prompt_shell.dart';
import 'package:notes/ui/updates/updates_screen.dart';
import 'package:notes/update/installer.dart';

import '../support/screenshot.dart';
import '../update/world.dart';

void main() {
  setUpAll(loadAppFonts);
  const sizes = <String, Size>{
    '360x640': Size(360, 640),
    '412x915': Size(412, 915),
    '800x360': Size(800, 360),
    '1280x800': Size(1280, 800),
  };

  for (final theme in AppTheme.values) {
    for (final entry in sizes.entries) {
      for (final scale in const [1.0, 1.4, 2.0]) {
        testWidgets('JSON warning ${theme.name} ${entry.key} x$scale', (
          tester,
        ) async {
          final services = AppServices.inMemory();
          services.settings.theme = theme;
          var pickerCalls = 0;
          addTearDown(services.close);
          await setWindow(tester, entry.value);
          await tester.pumpWidget(
            AppScope(
              services: services,
              child: MediaQuery(
                data: MediaQueryData(
                  size: entry.value,
                  textScaler: TextScaler.linear(scale),
                ),
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: buildTheme(services.settings),
                  home: DataScreen(
                    pickSaveFile: (_) async {
                      pickerCalls++;
                      return null;
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final semantics = tester.ensureSemantics();
          await tester.scrollUntilVisible(
            find.text('Export all notes'),
            80,
            scrollable: find.byType(Scrollable).first,
          );
          if (tester.getRect(find.text('Export all notes')).bottom >
              entry.value.height) {
            await tester.drag(find.byType(ListView), const Offset(0, -500));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.text('Export all notes'));
          await tester.pumpAndSettle();
          expect(find.text('Continue with JSON backup?'), findsOneWidget);
          expect(tester.getSemantics(find.text('Continue')), isNotNull);
          expect(tester.takeException(), isNull);
          for (final action in ['Cancel', 'Continue']) {
            final f = find.descendant(
              of: find.byType(AlertDialog),
              matching: find.widgetWithText(TextButton, action),
            );
            expect(f, findsOneWidget);
            expect(tester.getSize(f).height, greaterThanOrEqualTo(48));
          }
          if (entry.key == '360x640' && scale == 1.0) {
            await screenshot(tester, 'v1_2_json_${theme.name}_phone');
          } else if (entry.key == '1280x800' && scale == 1.0) {
            await screenshot(tester, 'v1_2_json_${theme.name}_desktop');
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(pickerCalls, 0);
          await tester.scrollUntilVisible(
            find.text('Export all notes'),
            80,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('Export all notes'));
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(pickerCalls, 1);
          expect(find.byType(AlertDialog), findsNothing);

          await tester.scrollUntilVisible(
            find.text('Export all notes'),
            80,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('Export all notes'));
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(pickerCalls, 1);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }
  }

  for (final theme in AppTheme.values) {
    for (final entry in sizes.entries) {
      for (final scale in const [1.0, 1.4]) {
        testWidgets('Retry surfaces ${theme.name} ${entry.key} x$scale', (
          tester,
        ) async {
          final world = await World.create();
          final services = AppServices.inMemory();
          services.settings.theme = theme;
          addTearDown(() {
            world.dispose();
            services.close();
          });
          await tester.runAsync(() async {
            await world.publish();
            await world.controller.check();
            await world.controller.download();
            world.installer.installResult = const InstallFailed(
              'A synthetic install attempt failed. Choose Retry.',
              retry: true,
            );
            await world.controller.install();
          });
          await setWindow(tester, entry.value);
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: entry.value,
                textScaler: TextScaler.linear(scale),
              ),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(services.settings),
                home: UpdatePromptShell(
                  controller: world.controller,
                  child: UpdatesScreen(
                    controller: world.controller,
                    settings: services.settings,
                    clock: () => world.now,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final semantics = tester.ensureSemantics();
          expect(find.text('Retry'), findsNWidgets(2));
          expect(tester.takeException(), isNull);
          final bannerRetry = find
              .descendant(
                of: find.byType(UpdatePromptShell),
                matching: find.text('Retry'),
              )
              .first;
          final retryButtons = find.widgetWithText(FilledButton, 'Retry');
          expect(retryButtons, findsNWidgets(2));
          for (var i = 0; i < retryButtons.evaluate().length; i++) {
            final button = retryButtons.at(i);
            expect(tester.getSemantics(button), isNotNull);
            expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          }
          if (entry.key == '360x640' && scale == 1.0) {
            await screenshot(tester, 'v1_2_retry_banner_${theme.name}_phone');
          } else if (entry.key == '1280x800' && scale == 1.0) {
            await screenshot(tester, 'v1_2_retry_banner_${theme.name}_desktop');
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.textContaining('Install version'), findsOneWidget);
          expect(bannerRetry, findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: entry.value,
                textScaler: TextScaler.linear(scale),
              ),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(services.settings),
                home: UpdatesScreen(
                  controller: world.controller,
                  settings: services.settings,
                  clock: () => world.now,
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.textContaining('Install version'), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }
  }
}
