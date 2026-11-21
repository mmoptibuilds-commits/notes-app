import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillRawEditorState;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/help/help_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/settings/settings_screen.dart';

import '../../support/screenshot.dart';
import 'support.dart';

/// Real-pointer regression tests for the Linux desktop bug where keyboard
/// shortcuts died after an ordinary mouse click: clicking away from the
/// search field unfocused it, focus fell to the route's own scope (above the
/// shortcut handlers), and nothing put it back.
void main() {
  setUpAll(loadAppFonts);

  const desktop = Size(1280, 800);

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

  Future<void> ctrlF(WidgetTester tester) =>
      key(tester, LogicalKeyboardKey.keyF, ctrl: true);

  /// A real mouse click (pointer down and up), as on the desktop.
  Future<void> click(WidgetTester tester, Offset at) async {
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
  }

  Future<void> clickWidget(WidgetTester tester, Finder f) =>
      click(tester, tester.getCenter(f.first));

  bool searchFocused(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

  String searchText(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).controller.text;

  /// Empty space in the library header, left of the search box (the title
  /// changes with the view, so this is placed relative to the search field).
  Offset blank(WidgetTester tester) =>
      tester.getTopLeft(find.byType(TextField).first) + const Offset(-120, 20);

  Future<Seed> open(WidgetTester tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: desktop);
    return s;
  }

  int noteRows(Seed s) =>
      s.services.db.raw.select('SELECT count(*) c FROM notes').first['c']
          as int;

  group('library', () {
    testWidgets('Ctrl+F still works after clicking elsewhere, repeatedly', (
      tester,
    ) async {
      await open(tester);
      for (var round = 0; round < 4; round++) {
        await ctrlF(tester);
        expect(searchFocused(tester), isTrue, reason: 'Ctrl+F round $round');
        await click(tester, blank(tester));
        expect(searchFocused(tester), isFalse, reason: 'click $round');
      }
    });

    testWidgets('/ works again after focus changes, repeatedly', (
      tester,
    ) async {
      await open(tester);
      for (var round = 0; round < 3; round++) {
        await key(tester, LogicalKeyboardKey.slash);
        expect(searchFocused(tester), isTrue, reason: '/ round $round');
        await click(tester, blank(tester));
      }
    });

    testWidgets('Escape after search and a click still clears the search', (
      tester,
    ) async {
      await open(tester);
      await ctrlF(tester);
      await tester.enterText(find.byType(TextField), 'tomato');
      await tester.pump(const Duration(milliseconds: 150));
      await click(tester, blank(tester));
      expect(searchText(tester), 'tomato');
      await key(tester, LogicalKeyboardKey.escape);
      expect(searchText(tester), isEmpty);
    });

    testWidgets('clicking a toolbar control then using shortcuts works', (
      tester,
    ) async {
      await open(tester);
      await ctrlF(tester);
      await openMenu(tester); // a real click on the overflow button
      await key(tester, LogicalKeyboardKey.escape); // dismisses the menu
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
      await click(tester, blank(tester));
      await key(tester, LogicalKeyboardKey.keyN, ctrl: true);
      expect(find.byType(EditorScreen), findsOneWidget);
    });

    testWidgets('Archive and Trash: Escape goes back, shortcuts survive', (
      tester,
    ) async {
      final s = await open(tester);
      s.services.notes.trash([s.ids['short']!]);
      s.services.notes.setArchived([s.ids['wifi']!], true);
      for (final view in ['Trash', 'Archive']) {
        await menuTap(tester, view);
        expect(libraryRoot(), findsNothing);
        await ctrlF(tester);
        expect(searchFocused(tester), isTrue, reason: '$view Ctrl+F');
        await click(tester, blank(tester));
        await key(tester, LogicalKeyboardKey.escape);
        await key(tester, LogicalKeyboardKey.escape);
        expect(
          libraryRoot(),
          findsOneWidget,
          reason: 'Escape returns from $view',
        );
      }
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
    });

    testWidgets('typing in search: / inserts, Delete never trashes notes', (
      tester,
    ) async {
      final s = await open(tester);
      final before = s.services.notes.counts().active;
      await ctrlF(tester);
      await tester.enterText(find.byType(TextField), 'a/b');
      expect(searchText(tester), 'a/b');
      await key(tester, LogicalKeyboardKey.delete);
      await key(tester, LogicalKeyboardKey.backspace);
      expect(s.services.notes.counts().active, before);
    });

    testWidgets('closing a dialog leaves shortcuts usable', (tester) async {
      await open(tester);
      await clickWidget(tester, find.byTooltip('New folder'));
      expect(find.byType(AlertDialog), findsOneWidget);
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(AlertDialog), findsNothing);
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
      await click(tester, blank(tester));
      await clickWidget(tester, find.byTooltip('New folder'));
      await tester.tapAt(const Offset(5, 5), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
    });
  });

  group('screens', () {
    testWidgets('Library, Editor, Library: keys work on every return', (
      tester,
    ) async {
      await open(tester);
      for (var round = 0; round < 2; round++) {
        await ctrlF(tester);
        await click(tester, blank(tester));
        await clickWidget(tester, find.text('Passport')); // opens the editor
        expect(find.byType(EditorScreen), findsOneWidget);
        await key(tester, LogicalKeyboardKey.escape);
        expect(find.byType(EditorScreen), findsNothing);
        await ctrlF(tester);
        expect(searchFocused(tester), isTrue, reason: 'round $round');
        await key(tester, LogicalKeyboardKey.keyN, ctrl: true);
        expect(find.byType(EditorScreen), findsOneWidget);
        await key(tester, LogicalKeyboardKey.escape);
      }
    });

    testWidgets('Library, Settings, Help and back: F1, Ctrl+, Escape', (
      tester,
    ) async {
      await open(tester);
      await ctrlF(tester);
      await click(tester, blank(tester));
      await key(tester, LogicalKeyboardKey.comma, ctrl: true);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await key(tester, LogicalKeyboardKey.f1); // F1 inside Settings
      expect(find.byType(HelpScreen), findsOneWidget);
      await click(tester, tester.getCenter(find.byType(HelpScreen)));
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(HelpScreen), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(SettingsScreen), findsNothing);
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
      await click(tester, blank(tester));
      await key(tester, LogicalKeyboardKey.f1);
      expect(find.byType(HelpScreen), findsOneWidget);
      await key(tester, LogicalKeyboardKey.escape);
      await key(tester, LogicalKeyboardKey.comma, ctrl: true);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('Escape in a Help search field leaves the field first', (
      tester,
    ) async {
      await open(tester);
      await key(tester, LogicalKeyboardKey.f1);
      await tester.enterText(find.byType(TextField), 'sync');
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(HelpScreen), findsOneWidget, reason: 'field first');
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(HelpScreen), findsNothing);
    });

    testWidgets('Editor: Ctrl+S and Escape work after clicking away', (
      tester,
    ) async {
      final s = await open(tester);
      await key(tester, LogicalKeyboardKey.keyN, ctrl: true);
      // The pane's title field is the last TextField (the search box is first).
      await tester.enterText(find.byType(TextField).last, 'Draft title');
      await tester.pump();
      final before = noteRows(s);
      expect(noteRows(s), before, reason: 'autosave has not fired yet');
      // Click empty app-bar space: the title field unfocuses itself.
      final bar =
          tester.getTopLeft(find.byTooltip('Close note')) +
          const Offset(120, 24);
      await click(tester, bar);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(noteRows(s), before + 1, reason: 'Ctrl+S saved immediately');
      await click(tester, bar);
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(EditorScreen), findsNothing);
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
    });
  });

  testWidgets('a long mixed session of clicks and keys keeps working', (
    tester,
  ) async {
    await open(tester);
    for (var i = 0; i < 3; i++) {
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue, reason: 'iteration $i Ctrl+F');
      await key(tester, LogicalKeyboardKey.escape);
      await click(tester, blank(tester));
      await key(tester, LogicalKeyboardKey.slash);
      expect(searchFocused(tester), isTrue, reason: 'iteration $i /');
      await click(tester, blank(tester));
      await key(tester, LogicalKeyboardKey.f1);
      expect(find.byType(HelpScreen), findsOneWidget, reason: 'iteration $i');
      await key(tester, LogicalKeyboardKey.escape);
      await key(tester, LogicalKeyboardKey.keyN, ctrl: true);
      expect(find.byType(EditorScreen), findsOneWidget, reason: 'iteration $i');
      await key(tester, LogicalKeyboardKey.escape);
    }
  });

  testWidgets('Escape leaves a new note while the Quill editor has focus', (
    tester,
  ) async {
    await open(tester);
    await key(tester, LogicalKeyboardKey.keyN, ctrl: true);
    // A new note autofocuses the Quill editor, which binds Escape itself.
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<QuillRawEditorState>(),
      isNotNull,
    );
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(EditorScreen), findsNothing);
  });

  testWidgets('Ctrl+F inside the editor opens Quill find without errors', (
    tester,
  ) async {
    await open(tester);
    await key(tester, LogicalKeyboardKey.keyN, ctrl: true);
    await key(tester, LogicalKeyboardKey.keyF, ctrl: true);
    expect(tester.takeException(), isNull);
    expect(find.byType(EditorScreen), findsOneWidget);
  });
}
