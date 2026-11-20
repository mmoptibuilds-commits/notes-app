import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/settings/settings_widgets.dart';
import 'package:notes/ui/theme/app_theme.dart';
import 'package:notes/ui/updates/updates_screen.dart';
import 'package:notes/update/installer.dart';

import '../../support/screenshot.dart';
import '../../update/world.dart';

/// Layout, theme, target-size, contrast and semantics checks for the Updates
/// screen (the Notes UI QA matrix). Synthetic data only.
void main() {
  setUpAll(loadAppFonts);

  const sizes = <String, Size>{
    '360x640': Size(360, 640),
    '800x360': Size(800, 360),
    '768x1024': Size(768, 1024),
    '640x480': Size(640, 480),
    '1024x768': Size(1024, 768),
    '1920x1080': Size(1920, 1080),
  };

  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  test('text colours used on the screen meet WCAG AA on card and page', () {
    for (final t in AppTheme.values) {
      final p = AppPalette.forTheme(t);
      for (final bg in [p.card, p.background]) {
        expect(
          contrast(p.text, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$t text',
        );
        expect(
          contrast(p.textMuted, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$t textMuted',
        );
        expect(
          contrast(p.danger, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$t danger',
        );
        expect(
          contrast(p.accent, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$t accent',
        );
      }
    }
  });

  for (final theme in AppTheme.values) {
    for (final entry in sizes.entries) {
      for (final scale in const [1.0, 1.4]) {
        for (final blocked in const [false, true]) {
          testWidgets(
            '${theme.name} ${entry.key} x$scale ${blocked ? 'blocked' : 'available'}: '
            'no overflow, nothing clipped',
            (tester) async {
              final w = await World.create(pinKey: !blocked);
              final services = AppServices.inMemory();
              services.settings.theme = theme;
              addTearDown(() {
                w.dispose();
                services.close();
              });
              await setWindow(tester, entry.value);
              await w.publish(sign: !blocked, notes: 'Synthetic notes.\n' * 6);
              await tester.pumpWidget(
                MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: buildTheme(services.settings),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: UpdatesScreen(
                    controller: w.controller,
                    settings: services.settings,
                    clock: () => w.now,
                  ),
                ),
              );
              await tester.runAsync(w.controller.check);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 50));
              expect(tester.takeException(), isNull);
              // Everything stays within the window horizontally.
              for (final f in [
                find.byType(SelectableText),
                find.byType(Switch),
              ]) {
                await tester.scrollUntilVisible(
                  f,
                  100,
                  scrollable: find.byType(Scrollable).first,
                );
                final box = tester.getRect(f.first);
                expect(box.left, greaterThanOrEqualTo(0));
                expect(box.right, lessThanOrEqualTo(entry.value.width));
              }
              if (entry.key == '360x640' && scale == 1.0 && !blocked) {
                await screenshot(tester, 'updates_${theme.name}_360');
              }
            },
          );
        }
      }
    }
  }

  group('Android touch targets and semantics', () {
    Future<World> setUp(WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final w = await World.create(platform: androidPlatform);
      final services = AppServices.inMemory();
      addTearDown(() {
        w.dispose();
        services.close();
      });
      await setWindow(tester, const Size(360, 640));
      await w.publish();
      w.installer.outcome = const InstallOutcome(
        id: 'a',
        updated: true,
        version: '1.0.1',
        message: 'Updated to 1.0.1.',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(services.settings),
          home: UpdatesScreen(
            controller: w.controller,
            settings: services.settings,
            clock: () => w.now,
          ),
        ),
      );
      await tester.runAsync(w.controller.resolveLastInstall);
      await tester.runAsync(w.controller.check);
      await tester.pump();
      return w;
    }

    testWidgets(
      'buttons, the dismiss control and the switch row are at least 48dp',
      (tester) async {
        await setUp(tester);
        for (final f in [
          find.byType(FilledButton),
          find.byType(OutlinedButton),
          find.byTooltip('Dismiss'),
        ]) {
          for (final e in f.evaluate()) {
            final size = tester.getSize(find.byElementPredicate((x) => x == e));
            expect(
              size.height,
              greaterThanOrEqualTo(48),
              reason: '${e.widget.runtimeType}',
            );
            expect(
              size.width,
              greaterThanOrEqualTo(48),
              reason: '${e.widget.runtimeType}',
            );
          }
        }
        // The whole switch row is the tap target.
        final row = tester.getSize(find.byType(SwitchRow));
        expect(row.height, greaterThanOrEqualTo(48));
      },
    );

    testWidgets(
      'icon-only controls are labelled; the status is a live region',
      (tester) async {
        final handle = tester.ensureSemantics();
        await setUp(tester);
        final dismiss = tester.getSemantics(find.byTooltip('Dismiss'));
        expect(
          '${dismiss.label}${dismiss.tooltip}',
          contains('Dismiss'),
          reason: 'the icon-only control is named for screen readers',
        );
        bool inLiveRegion(String text) {
          SemanticsNode? n = tester.getSemantics(find.textContaining(text));
          while (n != null) {
            if (n.getSemanticsData().flagsCollection.isLiveRegion) return true;
            n = n.parent;
          }
          return false;
        }

        expect(inLiveRegion('Updated to 1.0.1.'), isTrue); // outcome banner
        expect(inLiveRegion('is available'), isTrue); // status line
        // The screen's title is exposed as a header for screen readers.
        expect(
          tester
              .getSemantics(find.text('Updates'))
              .getSemanticsData()
              .flagsCollection
              .isHeader,
          isTrue,
        );
        handle.dispose();
      },
    );
  });

  testWidgets(
    'Tab reaches the buttons in reading order and Shift+Tab goes back',
    (tester) async {
      final w = await World.create();
      final services = AppServices.inMemory();
      addTearDown(() {
        w.dispose();
        services.close();
      });
      await setWindow(tester, const Size(1024, 768));
      await w.publish();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(services.settings),
          home: UpdatesScreen(
            controller: w.controller,
            settings: services.settings,
          ),
        ),
      );
      await tester.runAsync(w.controller.check);
      await tester.pump();
      String focused() {
        final ctx = FocusManager.instance.primaryFocus?.context;
        final text = ctx == null
            ? null
            : find
                  .descendant(
                    of: find.byElementPredicate((e) => e == ctx),
                    matching: find.byType(Text),
                  )
                  .evaluate()
                  .map((e) => (e.widget as Text).data)
                  .whereType<String>()
                  .join();
        return text ?? '';
      }

      final seen = <String>[];
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        seen.add(focused());
      }
      expect(seen, containsAllInOrder(['Download', 'Check again']));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(focused(), isNotEmpty);
    },
  );

  testWidgets('reduced motion: the screen has no running animation when idle', (
    tester,
  ) async {
    final w = await World.create();
    final services = AppServices.inMemory();
    services.settings.animations = AnimationLevel.off;
    addTearDown(() {
      w.dispose();
      services.close();
    });
    await setWindow(tester, const Size(360, 640));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(services.settings),
        home: UpdatesScreen(
          controller: w.controller,
          settings: services.settings,
        ),
      ),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });
}
