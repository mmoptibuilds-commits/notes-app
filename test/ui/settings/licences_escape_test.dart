import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/settings/settings_screen.dart';
import 'package:notes/ui/help/help_screen.dart';

import '../../support/screenshot.dart';
import '../library/support.dart';

const _wide = Size(1280, 1600);
const _narrow = Size(412, 2600);

Finder get _licencePage => find.byType(LicensePage);

Future<void> _escape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

Future<void> _tapLicencesRow(WidgetTester tester) async {
  final label = find.text('Open-source licences');
  await tester.ensureVisible(label);
  await tester.pumpAndSettle();
  await tester.tap(label);
  await tester.pumpAndSettle();
  expect(_licencePage, findsOneWidget);
}

Future<void> _openLicencesAt(WidgetTester tester, Size size) async {
  final services = AppServices.inMemory();
  addTearDown(services.close);
  await setWindow(tester, size);
  await pumpApp(tester, services);
  await menuTap(tester, 'Settings');
  expect(find.byType(SettingsScreen), findsOneWidget);
  await _tapLicencesRow(tester);
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('wide: Escape on the licence page returns to Settings', (
    tester,
  ) async {
    await _openLicencesAt(tester, _wide);
    await _escape(tester);
    expect(_licencePage, findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('narrow: Escape on a package detail goes to the list first', (
    tester,
  ) async {
    await _openLicencesAt(tester, _narrow);
    await tester.tap(find.text('Inter (font)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The Inter Project Authors'), findsWidgets);

    await _escape(tester);
    expect(_licencePage, findsOneWidget, reason: 'one Escape, one level');
    expect(find.text('Inter (font)'), findsOneWidget);
    expect(find.textContaining('The Inter Project Authors'), findsNothing);

    await _escape(tester);
    expect(_licencePage, findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('narrow: Escape on the list returns to Settings', (tester) async {
    await _openLicencesAt(tester, _narrow);
    await _escape(tester);
    expect(_licencePage, findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('wide: Escape after opening an entry returns to Settings once', (
    tester,
  ) async {
    await _openLicencesAt(tester, _wide);
    // At this width the first package is also in the detail pane: tap the list.
    await tester.tap(find.text('Inter (font)').first);
    await tester.pumpAndSettle();
    await _escape(tester);
    expect(_licencePage, findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(HelpScreen), findsNothing);
  });

  testWidgets('no double navigation: one Escape does not reach Library', (
    tester,
  ) async {
    await _openLicencesAt(tester, _wide);
    await _escape(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Escape after scrolling the list returns to Settings', (
    tester,
  ) async {
    await _openLicencesAt(tester, _wide);
    await tester.drag(
      find
          .descendant(of: _licencePage, matching: find.byType(Scrollable))
          .first,
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    await _escape(tester);
    expect(_licencePage, findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('visible Back button returns to Settings', (tester) async {
    await _openLicencesAt(tester, _wide);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(_licencePage, findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Android system back returns to Settings', (tester) async {
    await _openLicencesAt(tester, _wide);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_licencePage, findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('licences reopen cleanly after closing', (tester) async {
    await _openLicencesAt(tester, _wide);
    await _escape(tester);
    expect(_licencePage, findsNothing);
    await _tapLicencesRow(tester);
    expect(find.text('Inter (font)'), findsWidgets);
    await _escape(tester);
    expect(_licencePage, findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Help -> Licences -> Escape returns to Help', (tester) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, _narrow);
    await pumpApp(tester, services);
    await menuTap(tester, 'Settings');
    final helpRow = find.text('Help');
    await tester.tap(
      find.ancestor(of: helpRow, matching: find.byType(InkWell)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HelpScreen), findsOneWidget);

    await tester.tap(find.text('About and open-source licences'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open-source licences'));
    await tester.pumpAndSettle();
    expect(_licencePage, findsOneWidget);

    await _escape(tester);
    expect(_licencePage, findsNothing);
    expect(find.byType(HelpScreen), findsOneWidget);
  });

  testWidgets('bundled font licences are still listed', (tester) async {
    await _openLicencesAt(tester, _wide);
    for (final name in [
      'Inter (font)',
      'Source Serif 4 (font)',
      'JetBrains Mono (font)',
      'Atkinson Hyperlegible (font)',
    ]) {
      expect(find.text(name), findsWidgets, reason: name);
    }
  });
}
