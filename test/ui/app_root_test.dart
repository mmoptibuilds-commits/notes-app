import 'package:notes/ui/material.dart' show TextField;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/data/data_screen.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/help/help_screen.dart';
import 'package:notes/ui/library/library_screen.dart';
import 'package:notes/ui/onboarding/onboarding_screen.dart';
import 'package:notes/ui/settings/settings_screen.dart';

import '../support/screenshot.dart';

int noteRows(AppServices s) =>
    s.db.raw.select('SELECT count(*) c FROM notes').first['c'] as int;

void main() {
  setUpAll(loadAppFonts);

  Future<AppServices> start(
    WidgetTester tester, {
    bool pending = false,
    bool withNote = false,
  }) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    if (withNote) {
      services.notes.createNote(title: 'Existing', body: '[{"insert":"x\\n"}]');
    }
    if (pending) services.settings.write('onboarding', 'pending');
    await setWindow(tester, const Size(412, 915));
    await pumpApp(tester, services);
    return services;
  }

  group('first-use introduction', () {
    testWidgets('a normal start goes straight to the library', (tester) async {
      await start(tester);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(LibraryScreen), findsOneWidget);
    });

    testWidgets('a new install shows it; Skip marks it done, no notes made', (
      tester,
    ) async {
      final s = await start(tester, pending: true);
      expect(find.byType(OnboardingScreen), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(s.settings.onboardingPending, isFalse);
      expect(noteRows(s), 0);
    });

    testWidgets('Create a note opens the editor and creates nothing yet', (
      tester,
    ) async {
      final s = await start(tester, pending: true);
      await tester.tap(find.text('Create a note'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
      expect(s.settings.onboardingPending, isFalse);
      expect(noteRows(s), 0);
    });

    testWidgets('Import notes opens the data screen', (tester) async {
      final s = await start(tester, pending: true);
      await tester.tap(find.text('Import notes'));
      await tester.pumpAndSettle();
      expect(find.byType(DataScreen), findsOneWidget);
      expect(s.settings.onboardingPending, isFalse);
    });

    testWidgets('an install that already has notes never sees it', (
      tester,
    ) async {
      final s = await start(tester, pending: true, withNote: true);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(s.settings.onboardingPending, isFalse);
    });
  });

  group('shortcuts across screens', () {
    Future<void> key(
      WidgetTester tester,
      LogicalKeyboardKey k, {
      bool ctrl = false,
    }) async {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(k);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('F1 opens Help and lists the real shortcuts', (tester) async {
      await start(tester);
      await key(tester, LogicalKeyboardKey.f1);
      expect(find.byType(HelpScreen), findsOneWidget);
      final help = tester.widget<HelpScreen>(find.byType(HelpScreen));
      expect(help.shortcuts.map((e) => e.keys), contains('Ctrl+N'));
      expect(help.shortcuts.map((e) => e.keys), contains('F1'));
    });

    testWidgets('Ctrl+Comma opens Settings', (tester) async {
      await start(tester);
      await key(tester, LogicalKeyboardKey.comma, ctrl: true);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('library shortcuts do nothing while Settings is on top', (
      tester,
    ) async {
      await start(tester);
      await key(tester, LogicalKeyboardKey.comma, ctrl: true);
      await key(tester, LogicalKeyboardKey.keyN, ctrl: true);
      expect(find.byType(EditorScreen), findsNothing);
    });
  });

  testWidgets('Ctrl+S in the editor saves immediately and types nothing', (
    tester,
  ) async {
    final s = await start(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Draft title');
    await tester.pump();
    expect(noteRows(s), 0, reason: 'autosave has not fired yet');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(noteRows(s), 1);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'Draft title',
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });
}
