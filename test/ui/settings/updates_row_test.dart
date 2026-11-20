import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/settings/settings_screen.dart';
import 'package:notes/ui/updates/updates_screen.dart';

import '../../support/screenshot.dart';
import '../../update/world.dart';

void main() {
  setUpAll(loadAppFonts);

  Future<void> openSettings(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  }

  testWidgets('no updater (tests, unsupported platforms): no Updates row', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(1000, 800));
    await pumpApp(tester, services);
    await openSettings(tester);
    await tester.scrollUntilVisible(
      find.text('Open-source licences'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('App updates'), findsNothing);
  });

  testWidgets('App updates opens the Updates screen; Escape goes back', (
    tester,
  ) async {
    final base = AppServices.inMemory();
    final world = await World.create();
    final services = AppServices(
      base.db,
      NoteRepository(base.db),
      base.settings,
      '',
      updates: world.controller,
    );
    addTearDown(() {
      world.dispose();
      base.close();
    });
    await setWindow(tester, const Size(1000, 800));
    await pumpApp(tester, services);
    await openSettings(tester);
    await tester.scrollUntilVisible(
      find.text('App updates'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('App updates'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdatesScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(UpdatesScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
  });
}
