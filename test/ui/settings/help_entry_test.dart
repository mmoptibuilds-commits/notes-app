import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/help/help_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/settings/settings_screen.dart';

import '../../support/screenshot.dart';
import '../library/support.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('Settings has a Help row that opens Help and returns', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 2600));
    await pumpApp(tester, services);
    await menuTap(tester, 'Settings');
    expect(find.byType(SettingsScreen), findsOneWidget);

    final row = find.text('Help');
    expect(row, findsOneWidget);
    final tile = find.ancestor(of: row, matching: find.byType(InkWell));
    expect(tile, findsOneWidget);
    expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(HelpScreen), findsOneWidget);
    expect(find.text('Getting started'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('the licences row keeps its 48dp target next to Help', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 2600));
    await pumpApp(tester, services);
    await menuTap(tester, 'Settings');

    final label = find.text('Open-source licences');
    expect(label, findsOneWidget);
    final tile = find.ancestor(of: label, matching: find.byType(InkWell));
    expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
  });
}
