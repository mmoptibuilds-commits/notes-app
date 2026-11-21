import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/library/desktop_sidebar.dart';
import 'package:notes/ui/library/folder_strip.dart';
import 'package:notes/ui/library/library_header.dart';
import 'package:notes/ui/library/library_screen.dart';
import 'package:notes/ui/library/note_card.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/widgets/responsive.dart';

import '../../support/screenshot.dart';
import 'support.dart';

/// The desktop shell: sidebar, editor as a pane, and the resize rules.
void main() {
  setUpAll(loadAppFonts);

  const phone = Size(412, 915);
  const desktop = Size(1280, 800);

  Finder sidebar(String label) => find.descendant(
    of: find.byType(DesktopSidebar),
    matching: find.text(label),
  );

  Future<void> goto(WidgetTester tester, String label) async {
    await tester.tap(sidebar(label).first);
    await tester.pumpAndSettle();
  }

  QuillController quill(WidgetTester tester) =>
      tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;

  EditorScreen editor(WidgetTester tester) =>
      tester.widget<EditorScreen>(find.byType(EditorScreen));

  /// A note's row in the list (the open note's title also appears in the
  /// editor's title field).
  Finder row(String title) => find.descendant(
    of: find.byWidgetPredicate((w) => w is NoteCard || w is NoteRow),
    matching: find.text(title),
  );

  bool searchFocused(WidgetTester tester) {
    final field = find.byType(LibrarySearchField);
    if (field.evaluate().isEmpty) return false;
    return tester
        .widget<EditableText>(
          find.descendant(
            of: find.byType(LibrarySearchField),
            matching: find.byType(EditableText),
          ),
        )
        .focusNode
        .hasFocus;
  }

  Future<Seed> open(WidgetTester tester, {Size size = desktop}) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: size);
    await tester.pumpAndSettle();
    return s;
  }

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

  String body(Seed s, String key) =>
      s.services.notes.getNote(s.ids[key]!)!.body;

  group('sidebar', () {
    testWidgets('replaces the folder strip and the FAB', (tester) async {
      await open(tester);
      expect(find.byType(DesktopSidebar), findsOneWidget);
      expect(find.byType(FolderStrip), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('New note'), findsOneWidget);
      expect(sidebar('All notes'), findsOneWidget);
      for (final f in ['Work', 'Home', 'Reading']) {
        expect(sidebar(f), findsOneWidget);
      }
      for (final l in ['Archive', 'Trash', 'Settings', 'Help']) {
        expect(sidebar(l), findsOneWidget);
      }
    });

    testWidgets('navigates: folder, Archive, Trash, All notes', (tester) async {
      final s = await open(tester);
      s.services.notes.setArchived([s.ids['wifi']!], true);
      s.services.notes.trash([s.ids['short']!]);
      await tester.pumpAndSettle();

      await goto(tester, 'Work');
      expect(noteItems(), findsNWidgets(2));
      expect(find.text('Quarter roadmap'), findsOneWidget);
      expect(find.text('Wifi'), findsNothing);

      await goto(tester, 'Archive');
      expect(noteItems(), findsOneWidget);
      expect(find.text('Wifi'), findsOneWidget);

      await goto(tester, 'Trash');
      expect(noteItems(), findsOneWidget);
      expect(find.text('Passport'), findsOneWidget);

      await goto(tester, 'All notes');
      expect(find.text('Passport'), findsNothing);
      expect(find.text('Quarter roadmap'), findsOneWidget);
      expect(find.text('Tomato soup'), findsOneWidget);
    });

    testWidgets('New note opens a blank editor in the pane', (tester) async {
      await open(tester);
      await tester.tap(find.text('New note'));
      await tester.pumpAndSettle();
      expect(editor(tester).embedded, isTrue);
      expect(editor(tester).noteId, isNull);
      expect(find.byType(LibraryScreen), findsOneWidget);
    });

    testWidgets('phone keeps the strip and the FAB, no sidebar', (
      tester,
    ) async {
      await open(tester, size: phone);
      expect(find.byType(DesktopSidebar), findsNothing);
      expect(find.byType(FolderStrip), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('just below the breakpoint is still the phone layout', (
      tester,
    ) async {
      await open(tester, size: Size(desktopBreakpoint - 1, 800));
      expect(find.byType(DesktopSidebar), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });

  group('editor pane', () {
    testWidgets('a note opens beside the list, close returns', (tester) async {
      final s = await open(tester);
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      expect(editor(tester).embedded, isTrue);
      expect(editor(tester).noteId, s.ids['short']);
      expect(find.byType(LibraryScreen), findsOneWidget);
      // The list column stays, in list layout, with the sidebar.
      expect(find.byType(NoteRow), findsWidgets);
      expect(find.byType(NoteCard), findsNothing);
      expect(find.byType(DesktopSidebar), findsOneWidget);

      await tester.tap(find.byTooltip('Close note'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing);
      expect(find.byType(NoteCard), findsWidgets);
    });

    testWidgets('Escape from the editor closes the pane', (tester) async {
      final s = await open(tester);
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(QuillEditor));
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(EditorScreen), findsNothing);
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(s.services.notes.getNote(s.ids['short']!), isNotNull);
    });

    testWidgets('Escape from the list closes the pane', (tester) async {
      await open(tester);
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(EditorScreen), findsNothing);
    });

    testWidgets('switching notes saves the text; reopening shows it', (
      tester,
    ) async {
      final s = await open(tester);
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      quill(tester).replaceText(0, 0, 'ZEBRA ', null);
      await tester.pump(const Duration(milliseconds: 50));
      // Well inside the 700 ms autosave delay: only a flush on switch saves.
      expect(body(s, 'short'), isNot(contains('ZEBRA')));

      await tester.tap(row('Wifi'));
      await tester.pumpAndSettle();
      expect(editor(tester).noteId, s.ids['wifi']);
      expect(body(s, 'short'), contains('ZEBRA'));
      expect(body(s, 'wifi'), isNot(contains('ZEBRA')));
      expect(quill(tester).document.toPlainText(), isNot(contains('ZEBRA')));

      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      expect(quill(tester).document.toPlainText(), contains('ZEBRA'));
    });

    testWidgets('two new notes in a row do not share a draft', (tester) async {
      final s = await open(tester);
      final before = s.services.notes.counts().active;
      await tester.tap(find.text('New note'));
      await tester.pumpAndSettle();
      quill(tester).replaceText(0, 0, 'first draft', null);
      await tester.tap(find.text('New note'));
      await tester.pumpAndSettle();
      expect(quill(tester).document.toPlainText().trim(), isEmpty);
      expect(s.services.notes.counts().active, before + 1);
    });

    testWidgets('a new note becomes the highlighted open note once stored', (
      tester,
    ) async {
      final s = await open(tester);
      await tester.tap(find.text('New note'));
      await tester.pumpAndSettle();
      quill(tester).replaceText(0, 0, 'brand new', null);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(s.services.notes.counts().active, 12);
      expect(find.text('brand new'), findsWidgets);
    });

    testWidgets('trashing the open note closes the pane and keeps its text', (
      tester,
    ) async {
      final s = await open(tester);
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      quill(tester).replaceText(0, 0, 'LAST ', null);
      await tester.tap(find.byTooltip('More').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Trash'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing);
      final n = s.services.notes.getNote(s.ids['short']!)!;
      expect(n.isTrashed, isTrue);
      expect(n.body, contains('LAST'));
    });

    testWidgets('trashing it from the list saves, then closes the pane', (
      tester,
    ) async {
      final s = await open(tester);
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      quill(tester).replaceText(0, 0, 'KEPT ', null);
      await tester.tap(row('Passport'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Trash'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing);
      final n = s.services.notes.getNote(s.ids['short']!)!;
      expect(n.isTrashed, isTrue);
      expect(n.body, contains('KEPT'));
    });
  });

  group('keys with the editor focused', () {
    testWidgets('Delete, / and Ctrl+A do not act on the library', (
      tester,
    ) async {
      final s = await open(tester);
      final active = s.services.notes.counts().active;
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      // Start a selection in the list, then put focus in the editor.
      await selectByLongPress(tester, 'Wifi');
      expect(find.textContaining('selected'), findsOneWidget);
      await tester.tap(find.byType(QuillEditor));
      await tester.pumpAndSettle();

      await key(tester, LogicalKeyboardKey.delete);
      await key(tester, LogicalKeyboardKey.slash);
      await key(tester, LogicalKeyboardKey.keyA, ctrl: true);

      expect(s.services.notes.counts().active, active, reason: 'no trashing');
      expect(searchFocused(tester), isFalse, reason: '/ stays in the editor');
      expect(s.services.notes.getNote(s.ids['short']!)!.isTrashed, isFalse);
      expect(find.text('1 selected'), findsOneWidget, reason: 'unchanged');
      expect(find.byType(EditorScreen), findsOneWidget);
    });

    testWidgets('Ctrl+N still reaches the library', (tester) async {
      await open(tester);
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(QuillEditor));
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.keyN, ctrl: true);
      expect(editor(tester).noteId, isNull);
    });
  });

  group('resizing', () {
    testWidgets('wide to narrow with a pane saves unsaved text', (
      tester,
    ) async {
      final s = await open(tester);
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      quill(tester).replaceText(0, 0, 'RESIZED ', null);
      await tester.pump(const Duration(milliseconds: 20));

      await setWindow(tester, phone);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing);
      expect(find.byType(DesktopSidebar), findsNothing);
      expect(find.byType(FolderStrip), findsOneWidget);
      expect(body(s, 'short'), contains('RESIZED'));

      // Widening again does not resurrect the pane.
      await setWindow(tester, desktop);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing);
      expect(find.byType(DesktopSidebar), findsOneWidget);
    });

    testWidgets('narrow to wide keeps the open route and its text', (
      tester,
    ) async {
      final s = await open(tester, size: phone);
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      expect(editor(tester).embedded, isFalse);
      quill(tester).replaceText(0, 0, 'ROUTE ', null);

      await setWindow(tester, desktop);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
      expect(quill(tester).document.toPlainText(), contains('ROUTE'));

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing);
      expect(body(s, 'short'), contains('ROUTE'));
      expect(find.byType(DesktopSidebar), findsOneWidget);
    });
  });

  testWidgets('phone width still pushes the editor as a route', (tester) async {
    await open(tester, size: phone);
    await tester.tap(row('Passport'));
    await tester.pumpAndSettle();
    expect(editor(tester).embedded, isFalse);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Close note'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    expect(find.byType(LibraryScreen), findsOneWidget);
  });

  group('no overflow', () {
    final sizes = [
      const Size(900, 700),
      const Size(1024, 700),
      const Size(1280, 800),
      const Size(1440, 900),
      const Size(1920, 1080),
    ];
    for (final size in sizes) {
      for (final scale in [1.0, 1.4]) {
        testWidgets(
          '${size.width.toInt()}x${size.height.toInt()} at text $scale',
          (tester) async {
            final s = seedLibrary();
            addTearDown(s.services.close);
            s.services.settings.textScale = scale;
            await pumpLibrary(tester, s, size: size);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'library');
            await tester.tap(find.text('Groceries'));
            await tester.pumpAndSettle();
            expect(find.byType(EditorScreen), findsOneWidget);
            expect(tester.takeException(), isNull, reason: 'with pane');
          },
        );
      }
    }
  });
}
