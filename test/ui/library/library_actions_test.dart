import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/library/folder_strip.dart';
import 'package:notes/ui/library/note_card.dart';
import 'package:notes/ui/material.dart';

import '../../support/screenshot.dart';
import 'support.dart';

Finder chip(String name) =>
    find.descendant(of: find.byType(FolderStrip), matching: find.text(name));

Future<void> tapNewFolder(WidgetTester tester) async {
  await tester.drag(find.byType(FolderStrip), const Offset(-600, 0));
  await tester.pumpAndSettle();
  await tapTip(tester, 'New folder');
}

void main() {
  setUpAll(loadAppFonts);

  group('folders', () {
    testWidgets('chips filter, show counts and the choice persists', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Unfiled'), findsOneWidget);
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Tomato soup'), findsOneWidget);
      expect(find.text('Passport'), findsNothing);
      expect(s.services.settings.read('library.folder'), s.folders['Home']);

      // Restart: a fresh screen over the same settings opens on that folder.
      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester, s.services);
      await tester.pumpAndSettle();
      expect(find.text('Tomato soup'), findsOneWidget);
      expect(find.text('Passport'), findsNothing);

      await tester.tap(find.text('Unfiled'));
      await tester.pumpAndSettle();
      expect(s.services.settings.read('library.folder'), 'unfiled');
      expect(find.text('Passport'), findsOneWidget);
      expect(find.text('Tomato soup'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(s.services.settings.read('library.folder'), isNull);
    });

    testWidgets('no Unfiled chip without folders', (tester) async {
      final s = freshServices();
      addTearDown(s.services.close);
      s.services.notes.createNote(title: 'Solo', body: paragraphs(['x']));
      await pumpLibrary(tester, s);
      expect(find.text('Unfiled'), findsNothing);
      expect(find.byTooltip('New folder'), findsOneWidget);
    });

    testWidgets('+ creates a folder and opens it', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      await tapNewFolder(tester);
      await tester.enterText(find.byType(TextField), 'Travel');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(
        s.services.notes.listFolders().map((f) => f.name),
        contains('Travel'),
      );
      expect(find.text('No notes in this folder.'), findsOneWidget);
    });

    testWidgets('long-press renames; delete confirms and keeps notes', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      await tester.longPress(chip('Reading'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Books');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(chip('Books'), findsOneWidget);
      expect(chip('Reading'), findsNothing);

      await tester.tap(chip('Books'));
      await tester.pumpAndSettle();
      expect(s.services.settings.read('library.folder'), s.folders['Reading']);
      await tester.tap(chip('Books'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete folder'));
      await tester.pumpAndSettle();
      expect(find.textContaining('notes in it are kept'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        s.services.notes.listFolders().map((f) => f.name),
        contains('Books'),
      );

      await tester.tap(chip('Books'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete folder'));
      await tester.pumpAndSettle();
      expect(
        s.services.notes.listFolders().map((f) => f.name),
        isNot(contains('Books')),
      );
      expect(s.services.notes.getNote(s.ids['book']!), isNotNull);
      // The deleted folder was selected: the library falls back to All.
      expect(s.services.settings.read('library.folder'), isNull);
      expect(find.text('Passport'), findsOneWidget);
    });

    testWidgets('folder strip is hidden in Archive, Trash and Conflicts', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      expect(find.text('Work'), findsOneWidget);
      await menuTap(tester, 'Archive');
      expect(find.text('Work'), findsNothing);
      await menuTap(tester, 'Trash');
      expect(find.text('Work'), findsNothing);
    });
  });

  group('search', () {
    bool hasEmphasis(Widget w) {
      if (w is! RichText) return false;
      var found = false;
      w.text.visitChildren((span) {
        if (span is TextSpan &&
            span.style?.backgroundColor != null &&
            span.text != null) {
          found = true;
        }
        return true;
      });
      return found;
    }

    testWidgets('shows hits with emphasised snippet; clearing restores', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'washer');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(noteItems(), findsOneWidget);
      expect(find.byWidgetPredicate(hasEmphasis), findsOneWidget);
      expect(find.text('Passport'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(find.text('No notes match "zzzz".'), findsOneWidget);

      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(find.text('Passport'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
    });

    testWidgets('debounces typing', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'passpo');
      await tester.pump(const Duration(milliseconds: 50));
      expect(noteItems().evaluate().length, greaterThan(3));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(noteItems(), findsOneWidget);
    });

    testWidgets('archived hits carry a mark', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      s.services.notes.setArchived([s.ids['old']!], true);
      await pumpLibrary(tester, s);
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'lake');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(find.text('Archived'), findsOneWidget);
    });

    testWidgets('desktop shows the field in the header', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: const Size(1280, 800));
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byTooltip('Search'), findsNothing);
      await tester.enterText(find.byType(TextField), 'tomato');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(noteItems(), findsOneWidget);
    });
  });

  group('selection and bulk actions', () {
    testWidgets('long press selects; tap toggles; select all; clear', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      await selectByLongPress(tester, 'Passport');
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('Wifi'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.byType(EditorScreen), findsNothing);
      await tester.tap(find.text('Wifi'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tapTip(tester, 'Select all');
      expect(
        find.text('${s.services.notes.counts().active} selected'),
        findsOneWidget,
      );
      await tapTip(tester, 'Clear selection');
      expect(find.textContaining('selected'), findsNothing);
    });

    testWidgets('pin and unpin', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      await selectByLongPress(tester, 'Passport');
      await tester.tap(find.text('Wifi'));
      await tester.pumpAndSettle();
      await tapTip(tester, 'Pin');
      final repo = s.services.notes;
      expect(repo.getNote(s.ids['short']!)!.pinned, isTrue);
      expect(repo.getNote(s.ids['wifi']!)!.pinned, isTrue);
      expect(find.textContaining('selected'), findsNothing);
      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Unpin');
      expect(repo.getNote(s.ids['short']!)!.pinned, isFalse);
    });

    testWidgets('archive with Undo, then unarchive from Archive', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      final repo = s.services.notes;
      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Archive');
      expect(repo.getNote(s.ids['short']!)!.archived, isTrue);
      expect(find.text('Archived 1 note'), findsOneWidget);
      expect(find.text('Passport'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(repo.getNote(s.ids['short']!)!.archived, isFalse);
      expect(find.text('Passport'), findsOneWidget);

      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Archive');
      await tester.pump(const Duration(seconds: 6));
      await menuTap(tester, 'Archive');
      expect(find.text('Passport'), findsOneWidget);
      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Unarchive');
      expect(repo.getNote(s.ids['short']!)!.archived, isFalse);
      expect(find.text('Archive is empty.'), findsOneWidget);
    });

    testWidgets('move to folder: existing, none, and new', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      final repo = s.services.notes;
      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Move to folder');
      await tester.tap(
        find.descendant(of: find.byType(Dialog), matching: find.text('Work')),
      );
      await tester.pumpAndSettle();
      expect(repo.getNote(s.ids['short']!)!.folderId, s.folders['Work']);

      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Move to folder');
      await tester.tap(find.text('No folder'));
      await tester.pumpAndSettle();
      expect(repo.getNote(s.ids['short']!)!.folderId, isNull);

      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Move to folder');
      await tester.tap(find.text('New folder…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Admin');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      final admin = repo.listFolders().firstWhere((f) => f.name == 'Admin');
      expect(repo.getNote(s.ids['short']!)!.folderId, admin.id);
    });

    testWidgets('move to Trash with Undo', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      final repo = s.services.notes;
      await selectByLongPress(tester, 'Passport');
      await tester.tap(find.text('Wifi'));
      await tester.pumpAndSettle();
      await tapTip(tester, 'Move to Trash');
      expect(repo.counts().trash, 2);
      expect(find.text('Moved 2 notes to Trash'), findsOneWidget);
      expect(find.text('Passport'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(repo.counts().trash, 0);
      expect(find.text('Passport'), findsOneWidget);
    });

    testWidgets('snackbar goes away by itself', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Move to Trash');
      expect(find.text('Undo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsNothing);
    });
  });

  group('trash', () {
    Future<Seed> trashed(WidgetTester tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      s.services.notes.trash([s.ids['short']!, s.ids['wifi']!]);
      await pumpLibrary(tester, s);
      await menuTap(tester, 'Trash');
      return s;
    }

    testWidgets('lists trashed notes and offers restore / delete forever', (
      tester,
    ) async {
      await trashed(tester);
      expect(find.text('Trash'), findsOneWidget);
      expect(noteItems(), findsNWidgets(2));
      expect(libraryRoot(), findsNothing);
      await selectByLongPress(tester, 'Passport');
      expect(find.byTooltip('Restore'), findsOneWidget);
      expect(find.byTooltip('Delete forever'), findsOneWidget);
      expect(find.byTooltip('Pin'), findsNothing);
    });

    testWidgets('restore', (tester) async {
      final s = await trashed(tester);
      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Restore');
      expect(s.services.notes.getNote(s.ids['short']!)!.isTrashed, isFalse);
      expect(noteItems(), findsOneWidget);
    });

    testWidgets('delete forever asks first and says it cannot be undone', (
      tester,
    ) async {
      final s = await trashed(tester);
      await selectByLongPress(tester, 'Passport');
      await tapTip(tester, 'Delete forever');
      expect(find.text('Delete 1 note forever?'), findsOneWidget);
      expect(find.text('This cannot be undone.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(s.services.notes.getNote(s.ids['short']!), isNotNull);
      await tapTip(tester, 'Delete forever');
      await tester.tap(find.widgetWithText(TextButton, 'Delete forever'));
      await tester.pumpAndSettle();
      expect(s.services.notes.getNote(s.ids['short']!), isNull);
      expect(s.services.notes.getNote(s.ids['wifi']!), isNotNull);
    });

    testWidgets('empty Trash confirms with the count', (tester) async {
      final s = await trashed(tester);
      await menuTap(tester, 'Empty Trash');
      expect(
        find.textContaining('2 notes will be deleted forever'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(s.services.notes.counts().trash, 2);
      await menuTap(tester, 'Empty Trash');
      await tester.tap(find.widgetWithText(TextButton, 'Empty Trash'));
      await tester.pumpAndSettle();
      expect(s.services.notes.counts().trash, 0);
      expect(find.text('Trash is empty.'), findsOneWidget);
    });
  });

  group('conflicts', () {
    testWidgets('menu entry appears only with conflicts; keep and trash', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      await openMenu(tester);
      expect(find.text('Conflicts'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      markConflict(s, 'short');
      markConflict(s, 'wifi');
      await tester.pumpAndSettle();
      await menuTap(tester, 'Conflicts');
      expect(find.text('Conflicts'), findsOneWidget);
      expect(noteItems(), findsNWidgets(2));
      expect(find.text('Conflict copy'), findsNWidgets(2));

      await selectByLongPress(tester, 'Passport');
      expect(find.byTooltip('Keep as separate note'), findsOneWidget);
      await tapTip(tester, 'Keep as separate note');
      final repo = s.services.notes;
      expect(repo.getNote(s.ids['short']!)!.isConflictCopy, isFalse);
      expect(noteItems(), findsOneWidget);

      await selectByLongPress(tester, 'Wifi');
      await tapTip(tester, 'Move to Trash');
      expect(repo.getNote(s.ids['wifi']!)!.isTrashed, isTrue);
      expect(find.text('No conflicts.'), findsOneWidget);
    });
  });

  group('context menu', () {
    testWidgets('right-click offers single-note actions', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: const Size(1280, 800));
      final repo = s.services.notes;
      await tester.tap(find.text('Passport'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      for (final t in [
        'Open',
        'Select',
        'Pin',
        'Archive',
        'Move to folder…',
        'Move to Trash',
      ]) {
        expect(
          find.widgetWithText(PopupMenuItem<String>, t),
          findsOneWidget,
          reason: t,
        );
      }
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(repo.getNote(s.ids['short']!)!.pinned, isTrue);

      await tester.tap(find.text('Passport'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Trash'));
      await tester.pumpAndSettle();
      expect(repo.getNote(s.ids['short']!)!.isTrashed, isTrue);
    });

    testWidgets('in Trash: restore and delete forever', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      s.services.notes.trash([s.ids['short']!]);
      await pumpLibrary(tester, s, size: const Size(1280, 800));
      await menuTap(tester, 'Trash');
      await tester.tap(find.text('Passport'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Restore'), findsOneWidget);
      expect(find.text('Delete forever'), findsOneWidget);
      expect(find.text('Pin'), findsNothing);
    });
  });

  group('keyboard and back', () {
    Future<void> chord(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool ctrl = false,
      bool alt = false,
    }) async {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(key);
      if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    bool searchFocused(WidgetTester tester) => tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode
        .hasFocus;

    const desktop = Size(1280, 800);

    testWidgets('Ctrl+N opens a new note in the current folder', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: desktop);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      await chord(tester, LogicalKeyboardKey.keyN, ctrl: true);
      final editor = tester.widget<EditorScreen>(find.byType(EditorScreen));
      expect(editor.noteId, isNull);
      expect(editor.folderId, s.folders['Work']);
    });

    testWidgets('Ctrl+F and / focus search; typing / in it does not', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: desktop);
      expect(searchFocused(tester), isFalse);
      await chord(tester, LogicalKeyboardKey.keyF, ctrl: true);
      expect(searchFocused(tester), isTrue);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await chord(tester, LogicalKeyboardKey.escape);
      expect(searchFocused(tester), isFalse);
      await chord(tester, LogicalKeyboardKey.slash);
      expect(searchFocused(tester), isTrue);
      // Ctrl+A while typing in the field must not select notes.
      await chord(tester, LogicalKeyboardKey.keyA, ctrl: true);
      expect(find.textContaining('selected'), findsNothing);
    });

    testWidgets('Esc clears search, then exits selection', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: desktop);
      await tester.enterText(find.byType(TextField), 'tomato');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(noteItems(), findsOneWidget);
      await selectByLongPress(tester, 'Tomato soup');
      expect(find.text('1 selected'), findsOneWidget);
      await chord(tester, LogicalKeyboardKey.escape);
      expect(find.text('1 selected'), findsOneWidget, reason: 'search first');
      expect(noteItems().evaluate().length, greaterThan(3));
      await selectByLongPress(tester, 'Passport');
      await chord(tester, LogicalKeyboardKey.escape);
      expect(find.textContaining('selected'), findsNothing);
    });

    testWidgets('Esc leaves Trash and returns to all notes', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      s.services.notes.trash([s.ids['short']!]);
      await pumpLibrary(tester, s, size: desktop);
      await menuTap(tester, 'Trash');
      expect(libraryRoot(), findsNothing);
      await chord(tester, LogicalKeyboardKey.escape);
      expect(libraryRoot(), findsOneWidget);
    });

    testWidgets('Ctrl+A selects all and Delete trashes them', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: desktop);
      final active = s.services.notes.counts().active;
      await chord(tester, LogicalKeyboardKey.keyA, ctrl: true);
      expect(find.text('$active selected'), findsOneWidget);
      await chord(tester, LogicalKeyboardKey.delete);
      expect(s.services.notes.counts().active, 0);
      expect(s.services.notes.counts().trash, active);
    });

    testWidgets('Ctrl+click and Shift+click select instead of opening', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: desktop);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('Passport'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byType(EditorScreen), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('Wifi'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('Enter opens the focused card, which shows a focus ring', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await pumpLibrary(tester, s, size: desktop);
      bool onCard() =>
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<NoteCard>() !=
          null;
      for (var i = 0; i < 40 && !onCard(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(onCard(), isTrue);
      final focused = FocusManager.instance.primaryFocus!.context!;
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byWidget(
                focused.findAncestorWidgetOfExactType<NoteCard>()!,
              ),
              matching: find.byType(Material),
            )
            .first,
      );
      final side = (material.shape! as RoundedRectangleBorder).side;
      expect(side.width, 1.5, reason: 'visible focus ring');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
      expect(
        tester.widget<EditorScreen>(find.byType(EditorScreen)).noteId,
        isNotNull,
      );
    });

    testWidgets('Alt+Left leaves a sub-view', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: desktop);
      await menuTap(tester, 'Trash');
      expect(libraryTitle('Trash'), findsOneWidget);
      await chord(tester, LogicalKeyboardKey.arrowLeft, alt: true);
      expect(libraryTitle('All notes'), findsOneWidget);
    });

    testWidgets('Android back: selection, then search, then sub-view', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      s.services.notes.trash([s.ids['short']!]);
      await pumpLibrary(tester, s);
      await menuTap(tester, 'Trash');
      await selectByLongPress(tester, 'Passport');
      expect(find.text('1 selected'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.textContaining('selected'), findsNothing);
      expect(find.text('Trash'), findsOneWidget);

      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Trash'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('Trash'), findsNothing);
      expect(find.byType(NoteCard), findsWidgets);
    });
  });

  testWidgets('library follows repository changes without a rebuild', (
    tester,
  ) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s);
    expect(find.text('Brand new'), findsNothing);
    s.services.notes.createNote(
      title: 'Brand new',
      body: paragraphs(['hello']),
    );
    await tester.pumpAndSettle();
    expect(find.text('Brand new'), findsOneWidget);
    s.services.notes.createFolder('Fresh');
    await tester.pumpAndSettle();
    expect(find.text('Fresh'), findsOneWidget);
    expect(s.services.settings.layout, LibraryLayout.masonry);
    expect(s.services.notes.listNotes(sort: NoteSort.title), isNotEmpty);
    expect(s.services.notes.listFolders(), isA<List<Folder>>());
  });
}
