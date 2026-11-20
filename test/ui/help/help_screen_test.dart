import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/peers.dart' show maxDevices;
import 'package:notes/sync/sync_service.dart'
    show defaultSyncPort, discoveryPort;
import 'package:notes/ui/help/help_screen.dart';
import 'package:notes/ui/help/help_shortcut.dart';
import 'package:notes/ui/help/help_topics.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/onboarding/welcome_points.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../../support/screenshot.dart';

const _fakeShortcuts = [
  HelpShortcut(keys: 'Ctrl+N', description: 'Start a new note'),
  HelpShortcut(keys: 'Ctrl+F', description: 'Focus the search box'),
];

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

/// Expands the topic titled [title], scrolling the list to reach it first.
Future<void> _openTopic(WidgetTester tester, String title) async {
  final list = find.descendant(
    of: find.byType(ListView),
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(find.text(title), 150, scrollable: list);
  await tester.ensureVisible(find.text(title));
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

/// Every string a topic shows, flattened for accuracy checks.
String _allText() {
  final buf = StringBuffer();
  for (final t in helpTopics) {
    buf
      ..writeln(t.title)
      ..writeAll(t.paragraphs, '\n')
      ..writeAll(t.bullets, '\n')
      ..writeln();
  }
  for (final point in welcomePoints) {
    buf
      ..writeln(point.title)
      ..writeln(point.body);
  }
  return buf.toString();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('lists every topic title, starting with Welcome', (tester) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 3200));
    await tester.pumpWidget(
      _host(services.settings, const HelpScreen(shortcuts: [])),
    );

    expect(find.text('Help'), findsOneWidget);
    for (final t in helpTopics) {
      expect(find.text(t.title), findsOneWidget, reason: t.title);
    }
    expect(helpTopics.first.title, 'Welcome');
    expect(helpTopics.map((t) => t.id).toSet(), hasLength(helpTopics.length));
  });

  testWidgets('a topic expands to show its statements', (tester) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 3200));
    await tester.pumpWidget(
      _host(services.settings, const HelpScreen(shortcuts: [])),
    );

    expect(find.textContaining('TCP port $defaultSyncPort'), findsNothing);
    await tester.tap(find.text('Pairing another device'));
    await tester.pumpAndSettle();
    expect(find.textContaining('TCP port $defaultSyncPort'), findsOneWidget);
    expect(find.textContaining('UDP port $discoveryPort'), findsOneWidget);
  });

  testWidgets('shortcut list renders from the list it is given', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 3200));
    await tester.pumpWidget(
      _host(services.settings, const HelpScreen(shortcuts: _fakeShortcuts)),
    );

    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();
    expect(find.text('Ctrl+N'), findsOneWidget);
    expect(find.text('Start a new note'), findsOneWidget);
    expect(find.text('Ctrl+F'), findsOneWidget);
    expect(find.text('Focus the search box'), findsOneWidget);
  });

  testWidgets('empty shortcut list shows a neutral line, not a claim', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 3200));
    await tester.pumpWidget(
      _host(services.settings, const HelpScreen(shortcuts: [])),
    );

    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();
    expect(
      find.text('Keyboard shortcuts are not listed here yet.'),
      findsOneWidget,
    );
  });

  testWidgets('search narrows topics and shows a message when none match', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 3200));
    await tester.pumpWidget(
      _host(services.settings, const HelpScreen(shortcuts: [])),
    );

    await tester.enterText(find.byType(TextField), 'firewall');
    await tester.pumpAndSettle();
    expect(find.text('Pairing another device'), findsOneWidget);
    expect(find.text('Trash'), findsNothing);
    expect(find.text('Folders, pinned notes, archive and Trash'), findsNothing);
    expect(find.textContaining('TCP port $defaultSyncPort'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'zzqqxx');
    await tester.pumpAndSettle();
    expect(find.text('No help topics match "zzqqxx".'), findsOneWidget);
  });

  testWidgets('Welcome topic shows the same points as first run', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 3200));
    await tester.pumpWidget(
      _host(services.settings, const HelpScreen(shortcuts: [])),
    );

    await tester.tap(find.text('Welcome'));
    await tester.pumpAndSettle();
    for (final point in welcomePoints) {
      expect(find.text(point.title), findsOneWidget, reason: point.title);
    }
  });

  testWidgets('About shows the version and calls the licence action', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 3200));
    var opened = 0;
    await tester.pumpWidget(
      _host(
        services.settings,
        HelpScreen(
          shortcuts: const [],
          appVersion: '9.9.9',
          onOpenLicences: () => opened++,
        ),
      ),
    );

    await tester.tap(find.text('About and open-source licences'));
    await tester.pumpAndSettle();
    expect(find.text('Version 9.9.9'), findsOneWidget);
    await tester.tap(find.text('Open-source licences'));
    expect(opened, 1);
  });

  testWidgets('licence button is hidden when no action is given', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 3200));
    await tester.pumpWidget(
      _host(services.settings, const HelpScreen(shortcuts: [])),
    );

    await tester.tap(find.text('About and open-source licences'));
    await tester.pumpAndSettle();
    expect(find.text('Open-source licences'), findsNothing);
  });

  test('statements agree with the constants in the code', () {
    final text = _allText();
    // Ports are checked against the sync service's constants.
    expect(text, contains('TCP port $defaultSyncPort'));
    expect(text, contains('UDP port $discoveryPort'));
    // The device limit is the constant, minus this device.
    expect(maxDevices, 5);
    expect(text, contains('up to four other devices, five in total'));
    // Exports are plain JSON and must say so; Tailscale is unverified.
    expect(text, contains('Exported files are not encrypted'));
  });

  for (final size in const [Size(320, 640), Size(1280, 800)]) {
    for (final theme in AppTheme.values) {
      testWidgets('no overflow at 1.4 text scale, ${size.width.toInt()} wide, '
          '${theme.name} theme, with a topic and shortcuts open', (
        tester,
      ) async {
        final services = AppServices.inMemory();
        addTearDown(services.close);
        await setWindow(tester, size);
        services.settings.theme = theme;
        await tester.pumpWidget(
          _host(
            services.settings,
            const HelpScreen(shortcuts: _fakeShortcuts, appVersion: '1.0.0'),
            textScale: 1.4,
          ),
        );
        await tester.pumpAndSettle();
        await _openTopic(tester, 'Pairing another device');
        expect(tester.takeException(), isNull);
        await _openTopic(tester, 'Keyboard shortcuts');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
