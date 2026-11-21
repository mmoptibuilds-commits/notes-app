import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/library/desktop_sidebar.dart';
import 'package:notes/ui/library/library_header.dart';
import 'package:notes/ui/library/library_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/library/note_card.dart';

import '../../support/screenshot.dart';
import 'support.dart';

void main() {
  setUpAll(loadAppFonts);

  const desktop = Size(1280, 800);

  Finder row(String title) => find.descendant(
    of: find.byWidgetPredicate((w) => w is NoteCard || w is NoteRow),
    matching: find.text(title),
  );

  Future<Seed> openLibrary(WidgetTester tester) async {
    final seed = seedLibrary();
    addTearDown(seed.services.close);
    await pumpLibrary(tester, seed, size: desktop);
    await tester.pumpAndSettle();
    return seed;
  }

  testWidgets('purging the open note closes the pane without resurrecting it', (
    tester,
  ) async {
    final seed = await openLibrary(tester);
    final id = seed.ids['short']!;
    await tester.tap(row('Passport'));
    await tester.pumpAndSettle();

    final quill = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    quill.replaceText(0, 0, 'unsaved remote conflict', null);
    await tester.pump(const Duration(milliseconds: 20));

    // Apply the tombstone record as sync does; the library must treat it as
    // permanently deleted even though getRecord still returns the row.
    final incoming = seed.services.notes.getRecord(id)!.copyWith(purged: true);
    seed.services.db.transaction(
      () => seed.services.notes.writeRecord(incoming),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsNothing);
    expect(seed.services.notes.getRecord(id)!.purged, isTrue);
    expect(seed.services.notes.getNote(id), isNull);
    expect(find.byType(LibraryScreen), findsOneWidget);
  });

  testWidgets('restoring the open note from Trash reloads the pane', (
    tester,
  ) async {
    final seed = await openLibrary(tester);
    final id = seed.ids['short']!;
    seed.services.notes.trash([id]);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(DesktopSidebar),
        matching: find.text('Trash'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(row('Passport'));
    await tester.pumpAndSettle();
    expect(find.text('This note is in Trash'), findsOneWidget);

    await tester.longPress(row('Passport'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Restore'));
    await tester.pumpAndSettle();

    expect(seed.services.notes.getNote(id)!.isTrashed, isFalse);
    expect(find.text('This note is in Trash'), findsNothing);
    expect(find.byTooltip('Bold'), findsOneWidget);
  });

  testWidgets(
    'Escape closes the pane and Delete cannot trash stale selection',
    (tester) async {
      final seed = await openLibrary(tester);
      final id = seed.ids['wifi']!;
      await tester.tap(row('Passport'));
      await tester.pumpAndSettle();
      await tester.longPress(row('Wifi'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byType(QuillEditor));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(seed.services.notes.getNote(id)!.isTrashed, isFalse);
    },
  );

  testWidgets('Ctrl+F from the pane title does not focus library search', (
    tester,
  ) async {
    final seed = await openLibrary(tester);
    await tester.tap(row('Passport'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(EditorScreen),
        matching: find.byType(TextField),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final search = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(LibrarySearchField),
        matching: find.byType(EditableText),
      ),
    );
    expect(search.focusNode.hasFocus, isFalse);
    expect(seed.services.notes.getNote(seed.ids['short']!), isNotNull);
  });

  testWidgets('Ctrl+F from the pane body does not focus library search', (
    tester,
  ) async {
    final seed = await openLibrary(tester);
    await tester.tap(row('Passport'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(QuillEditor));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final search = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(LibrarySearchField),
        matching: find.byType(EditableText),
      ),
    );
    expect(search.focusNode.hasFocus, isFalse);
    expect(seed.services.notes.getNote(seed.ids['short']!), isNotNull);
  });

  testWidgets('changing sidebar destination flushes and closes the pane', (
    tester,
  ) async {
    final seed = await openLibrary(tester);
    await tester.tap(row('Passport'));
    await tester.pumpAndSettle();
    final quill = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    quill.replaceText(0, 0, 'saved before navigation ', null);
    await tester.pump(const Duration(milliseconds: 20));

    await tester.tap(
      find.descendant(
        of: find.byType(DesktopSidebar),
        matching: find.text('Work'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EditorScreen), findsNothing);
    expect(
      seed.services.notes.getNote(seed.ids['short']!)!.body,
      contains('saved before navigation'),
    );
    expect(find.text('Quarter roadmap'), findsOneWidget);
  });
}
