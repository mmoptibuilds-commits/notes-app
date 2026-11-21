import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/core/app_version.dart';
import 'package:notes/ui/settings/settings_screen.dart';
import 'package:notes/ui/settings/settings_widgets.dart';
import 'package:notes/ui/settings/toolbar_settings_screen.dart';
import 'package:notes/ui/theme/app_theme.dart';
import 'package:notes/ui/toolbar_item_info.dart';

import '../../support/screenshot.dart';
import '../library/support.dart';

Future<AppServices> openSettings(
  WidgetTester tester, {
  Size size = const Size(412, 2600),
  String dataDir = '',
}) async {
  final base = AppServices.inMemory();
  final services = AppServices(base.db, base.notes, base.settings, dataDir);
  addTearDown(services.close);
  await setWindow(tester, size);
  await pumpApp(tester, services);
  await menuTap(tester, 'Settings');
  expect(find.byType(SettingsScreen), findsOneWidget);
  return services;
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('reachable from the overflow menu; has all four sections', (
    tester,
  ) async {
    await openSettings(tester);
    for (final t in ['Appearance', 'Library', 'Editor', 'About']) {
      expect(find.text(t), findsWidgets, reason: t);
    }
    expect(find.text('Version $appVersionText'), findsOneWidget);
    expect(find.text('Data folder'), findsNothing, reason: 'dataDir is empty');
  });

  testWidgets('settings root fits at 2x system text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await openSettings(tester, size: const Size(360, 2000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('data folder is shown and selectable when known', (tester) async {
    await openSettings(tester, dataDir: '/home/someone/notes-data');
    expect(find.text('Data folder'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('/home/someone/notes-data'), findsOneWidget);
  });

  testWidgets('open-source licences are reachable and include bundled fonts', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await openSettings(tester);
    final label = find.text('Open-source licences');
    await tester.scrollUntilVisible(
      label,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final tile = find.ancestor(of: label, matching: find.byType(InkWell));
    expect(tile, findsOneWidget);
    expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel(RegExp('Open-source licences')), findsWidgets);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('Inter (font)'), findsOneWidget);
    await tester.tap(find.text('Inter (font)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The Inter Project Authors'), findsWidgets);
    expect(find.textContaining('SIL OPEN FONT LICENSE'), findsWidgets);
    semantics.dispose();
  });

  test(
    'font licence assets are declared in pubspec and carry the OFL text',
    () {
      const assets = [
        'assets/fonts/Inter-OFL.txt',
        'assets/fonts/SourceSerif4-OFL.txt',
        'assets/fonts/JetBrainsMono-OFL.txt',
        'assets/fonts/AtkinsonHyperlegible-OFL.txt',
      ];
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final asset in assets) {
        expect(pubspec, contains('- $asset'), reason: asset);
        final text = File(asset).readAsStringSync();
        expect(text, contains('SIL OPEN FONT LICENSE'), reason: asset);
        expect(text, contains('Copyright'), reason: asset);
      }
    },
  );

  testWidgets('appearance controls write their settings', (tester) async {
    final s = await openSettings(tester);
    final st = s.settings;
    await tester.tap(find.text('Charcoal'));
    await tester.pumpAndSettle();
    expect(st.theme, AppTheme.charcoal);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(st.theme, AppTheme.light);
    await tester.tap(find.text('AMOLED'));
    await tester.pumpAndSettle();
    expect(st.theme, AppTheme.amoled);

    await tester.tap(find.text('Interface font'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Source Serif'));
    await tester.pumpAndSettle();
    expect(st.uiFont, AppFont.serif);

    await tester.tap(find.text('Reduced'));
    await tester.pumpAndSettle();
    expect(st.animations, AnimationLevel.reduced);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(st.animations, AnimationLevel.off);
    await tester.tap(find.text('Full'));
    await tester.pumpAndSettle();
    expect(st.animations, AnimationLevel.full);
  });

  testWidgets('text size previews while dragging and commits on release', (
    tester,
  ) async {
    final s = await openSettings(tester);
    expect(s.settings.textScale, 1.0);
    final slider = find.byType(Slider).first;
    final g = await tester.startGesture(tester.getCenter(slider));
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(s.settings.textScale, 1.0, reason: 'not committed mid-drag');
    expect(find.textContaining('%'), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
    expect(s.settings.textScale, greaterThan(1.0));
  });

  testWidgets('library controls write layout, sort and preview lines', (
    tester,
  ) async {
    final s = await openSettings(tester);
    final st = s.settings;
    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
    expect(st.layout, LibraryLayout.list);
    await tester.tap(find.text('Grid'));
    await tester.pumpAndSettle();
    expect(st.layout, LibraryLayout.grid);
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    expect(st.sort, NoteSort.title);
    await tester.tap(find.text('Created'));
    await tester.pumpAndSettle();
    expect(st.sort, NoteSort.created);

    final lines = find.byType(Slider).at(1);
    await tester.drag(lines, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(st.previewLines, 0);
    expect(find.text('None'), findsOneWidget);
    await tester.drag(lines, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(st.previewLines, 10);
  });

  testWidgets('Start in offers all startup views', (tester) async {
    final s = await openSettings(tester);
    expect(s.settings.startupView, StartupView.unfiled);
    expect(find.text('Start in'), findsOneWidget);
    for (final label in ['Unfiled', 'All notes', 'Last viewed']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('Last viewed'));
    await tester.pumpAndSettle();
    expect(s.settings.startupView, StartupView.last);
    await tester.tap(find.text('All notes'));
    await tester.pumpAndSettle();
    expect(s.settings.startupView, StartupView.all);
    await tester.tap(find.text('Unfiled'));
    await tester.pumpAndSettle();
    expect(s.settings.startupView, StartupView.unfiled);
  });

  testWidgets('editor controls write their settings', (tester) async {
    final s = await openSettings(tester);
    final st = s.settings;
    await tester.tap(find.text('Note font'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JetBrains Mono'));
    await tester.pumpAndSettle();
    expect(st.editorFont, AppFont.mono);

    final size = find.byType(Slider).at(2);
    await tester.drag(size, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(st.editorFontSize, 28);
    final height = find.byType(Slider).at(3);
    await tester.drag(height, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(st.editorLineHeight, closeTo(1.1, 0.001));

    expect(st.completedSection, isTrue);
    await tester.tap(
      find.text('Move completed checklist items to a collapsible section'),
    );
    await tester.pumpAndSettle();
    expect(st.completedSection, isFalse);
    expect(st.completedCollapsed, isTrue);
    await tester.tap(find.text('Start with completed section collapsed'));
    await tester.pumpAndSettle();
    expect(st.completedCollapsed, isFalse);
  });

  testWidgets('desktop: content is a centred column of at most 640px', (
    tester,
  ) async {
    await openSettings(tester, size: const Size(1280, 1600));
    final box = tester.getRect(find.byType(SettingsSection).first);
    expect(box.width, lessThanOrEqualTo(640));
    expect(box.center.dx, closeTo(640, 1));
  });

  group('toolbar customisation', () {
    Future<AppServices> openToolbar(
      WidgetTester tester, {
      Size size = const Size(412, 2600),
    }) async {
      final s = await openSettings(tester, size: size);
      await tester.scrollUntilVisible(
        find.text('Customise toolbar'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Customise toolbar'));
      await tester.pumpAndSettle();
      return s;
    }

    testWidgets('toolbar settings fit at 2x system text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final s = AppServices.inMemory();
      addTearDown(s.close);
      await setWindow(tester, const Size(360, 800));
      await tester.pumpWidget(
        AppScope(
          services: s,
          child: ListenableBuilder(
            listenable: s.settings,
            builder: (context, _) => MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(s.settings),
              home: const ToolbarSettingsScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Reset to default'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lists every item, enabled first in saved order', (
      tester,
    ) async {
      await setWindow(tester, const Size(412, 2600));
      await openToolbar(tester);
      for (final t in ToolbarItem.values) {
        expect(find.text(t.label), findsOneWidget, reason: t.name);
      }
      final first = tester.getTopLeft(find.text('Checklist')).dy;
      final bold = tester.getTopLeft(find.text('Bold')).dy;
      final underline = tester.getTopLeft(find.text('Underline')).dy;
      expect(first, lessThan(bold));
      expect(bold, lessThan(underline), reason: 'hidden items come last');
    });

    testWidgets('switch hides and shows an item', (tester) async {
      final s = await openToolbar(tester);
      Finder switchOf(String label) => find.descendant(
        of: find
            .ancestor(of: find.text(label), matching: find.byType(Row))
            .first,
        matching: find.byType(Switch),
      );
      await tester.tap(switchOf('Bold'));
      await tester.pumpAndSettle();
      expect(s.settings.toolbar, isNot(contains(ToolbarItem.bold)));
      await tester.tap(switchOf('Underline'));
      await tester.pumpAndSettle();
      expect(s.settings.toolbar, contains(ToolbarItem.underline));
      await tester.tap(switchOf('Bold'));
      await tester.pumpAndSettle();
      expect(s.settings.toolbar, contains(ToolbarItem.bold));
    });

    testWidgets('Android toolbar switches have 48 dp targets', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await openToolbar(tester);
      for (final sw in find.byType(Switch).evaluate()) {
        expect(
          tester.getSize(find.byWidget(sw.widget)).height,
          greaterThanOrEqualTo(48),
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('drag reorders and writes the order', (tester) async {
      final s = await openToolbar(tester);
      expect(s.settings.toolbar.first, ToolbarItem.checklist);
      final handle = find.byIcon(Icons.drag_indicator_rounded).first;
      await tester.drag(handle, const Offset(0, 190));
      await tester.pumpAndSettle();
      final t = s.settings.toolbar;
      expect(t.take(3), [
        ToolbarItem.bold,
        ToolbarItem.italic,
        ToolbarItem.checklist,
      ]);
      expect(t.length, ToolbarItem.defaults.length);
    });

    testWidgets('reset to default restores the default toolbar', (
      tester,
    ) async {
      final s = await openToolbar(tester);
      s.settings.toolbar = [ToolbarItem.link];
      await tester.tap(find.byTooltip('Reset to default'));
      await tester.pumpAndSettle();
      expect(s.settings.toolbar, ToolbarItem.defaults);
    });

    testWidgets('the settings row reports how many are shown', (tester) async {
      final s = await openSettings(tester);
      expect(
        find.text(
          '${s.settings.toolbar.length} of ${ToolbarItem.values.length} buttons shown',
        ),
        findsOneWidget,
      );
    });
  });
}
