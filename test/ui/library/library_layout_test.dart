import 'package:flutter/gestures.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/library/library_layout.dart';
import 'package:notes/ui/library/library_screen.dart';
import 'package:notes/ui/library/note_card.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/widgets/format.dart';

import '../../support/screenshot.dart';
import 'support.dart';

void main() {
  setUpAll(loadAppFonts);

  group('column count', () {
    test('phone, laptop and full-HD widths', () {
      expect(columnCount(412 - 24), 2);
      expect(columnCount(1280 - 32), 6);
      expect(columnCount(1920 - 32), 9);
    });

    test('never fewer than two, never wider than the cap', () {
      expect(columnCount(300), 2);
      for (var w = 300.0; w < 3000; w += 17) {
        final cols = columnCount(w);
        expect(cols, greaterThanOrEqualTo(2));
        expect(
          (w - (cols - 1) * cardGap) / cols,
          lessThanOrEqualTo(maxCardWidth),
        );
      }
    });

    test('list is centred with a max width on desktop', () {
      expect(contentInset(412, list: true), 12);
      expect(contentInset(1280, list: true), (1280 - listMaxWidth) / 2);
    });

    for (final (w, cols) in [(412.0, 2), (1280.0, 5), (1920.0, 8)]) {
      testWidgets('grid and masonry use $cols columns at ${w.toInt()}px', (
        tester,
      ) async {
        final s = seedLibrary();
        addTearDown(s.services.close);
        s.services.settings.layout = LibraryLayout.grid;
        await pumpLibrary(tester, s, size: Size(w, 900));
        final grid = tester.widget<SliverGrid>(find.byType(SliverGrid).first);
        expect(
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          cols,
        );
        s.services.settings.layout = LibraryLayout.masonry;
        await tester.pumpAndSettle();
        final m = tester.widget<SliverMasonryGrid>(
          find.byType(SliverMasonryGrid).first,
        );
        expect(
          (m.gridDelegate as SliverSimpleGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          cols,
        );
      });
    }
  });

  testWidgets('three layouts render and switch from the overflow menu', (
    tester,
  ) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s);
    expect(find.byType(SliverMasonryGrid), findsWidgets);
    expect(find.byType(NoteCard), findsWidgets);

    await menuTap(tester, 'Grid');
    expect(s.services.settings.layout, LibraryLayout.grid);
    expect(find.byType(SliverGrid), findsWidgets);
    expect(find.byType(SliverMasonryGrid), findsNothing);

    await menuTap(tester, 'List');
    expect(s.services.settings.layout, LibraryLayout.list);
    expect(find.byType(NoteRow), findsWidgets);
    expect(find.byType(NoteCard), findsNothing);

    await menuTap(tester, 'Masonry');
    expect(find.byType(SliverMasonryGrid), findsWidgets);
  });

  testWidgets('sort from the menu reorders and persists', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.layout = LibraryLayout.list;
    await pumpLibrary(tester, s);
    await menuTap(tester, 'Title');
    expect(s.services.settings.sort, NoteSort.title);
    final first = tester.getTopLeft(find.text('Ideas')).dy;
    final later = tester.getTopLeft(find.text('Passport')).dy;
    expect(first, lessThan(later));
  });

  testWidgets('card shows title, preview, date, progress, pin and conflict', (
    tester,
  ) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    markConflict(s, 'short');
    s.services.settings.layout = LibraryLayout.grid;
    await pumpLibrary(tester, s);
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('3/7'), findsOneWidget);
    expect(find.text('5 min'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_rounded), findsWidgets);
    expect(find.text('Conflict copy'), findsOneWidget);
    // Untitled note: first preview line carries the weight.
    expect(
      find.text('Call the plumber about the kitchen leak'),
      findsOneWidget,
    );
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('Others'), findsOneWidget);
  });

  testWidgets('preview lines setting limits the preview', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.previewLines = 0;
    await pumpLibrary(tester, s);
    expect(find.textContaining('Tidy the importer'), findsNothing);
    s.services.settings.previewLines = 4;
    await tester.pumpAndSettle();
    expect(find.textContaining('Tidy the importer'), findsOneWidget);
  });

  testWidgets('empty library shows one muted line, no FAB clutter in trash', (
    tester,
  ) async {
    final s = freshServices();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s);
    expect(find.text('No notes yet. Tap + to write one.'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    await menuTap(tester, 'Trash');
    expect(find.text('Trash is empty.'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    await menuTap(tester, 'Archive');
    expect(find.text('Archive is empty.'), findsOneWidget);
  });

  testWidgets('FAB opens the editor in the current folder', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    final editor = tester.widget<EditorScreen>(find.byType(EditorScreen));
    expect(editor.folderId, s.folders['Home']);
    expect(editor.noteId, isNull);
  });

  group('scroll position', () {
    Seed many() {
      final s = freshServices();
      for (var i = 0; i < 80; i++) {
        s.clock.ms += 1000;
        s.services.notes.createNote(
          title: 'Note $i',
          body: paragraphs(['Line one of note $i', 'Line two', 'Line three']),
        );
      }
      return s;
    }

    ScrollPosition position(WidgetTester tester) => scrollPosition(tester);

    for (final layout in LibraryLayout.values) {
      testWidgets('survives the editor round trip in $layout', (tester) async {
        final s = many();
        addTearDown(s.services.close);
        s.services.settings.layout = layout;
        await pumpLibrary(tester, s);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
        await tester.pumpAndSettle();
        final before = position(tester).pixels;
        expect(before, greaterThan(500));

        await tester.tap(noteItems().at(3));
        await tester.pumpAndSettle();
        expect(find.byType(EditorScreen), findsOneWidget);
        // A change lands while the editor is open.
        s.services.notes.setPinned([
          s.services.notes.listNotes().last.id,
        ], true);
        Navigator.of(tester.element(find.byType(EditorScreen))).pop();
        await tester.pumpAndSettle();
        expect(position(tester).pixels, before);
      });

      testWidgets('survives a repository change while scrolled in $layout', (
        tester,
      ) async {
        final s = many();
        addTearDown(s.services.close);
        s.services.settings.layout = layout;
        await pumpLibrary(tester, s);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
        await tester.pumpAndSettle();
        final before = position(tester).pixels;
        final victim = s.services.notes.listNotes()[40].id;
        s.services.notes.saveContent(
          victim,
          title: 'Edited elsewhere',
          body: paragraphs(['changed']),
          base: s.services.notes.getNote(victim)!.contentVv,
        );
        await tester.pumpAndSettle();
        expect(position(tester).pixels, before);
      });
    }

    testWidgets('each view keeps its own offset', (tester) async {
      final s = many();
      addTearDown(s.services.close);
      s.services.settings.layout = LibraryLayout.list;
      final folder = s.services.notes.createFolder('Work');
      s.services.notes.moveToFolder(
        s.services.notes.listNotes().map((n) => n.id).take(60),
        folder.id,
      );
      await pumpLibrary(tester, s);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
      await tester.pumpAndSettle();
      final all = position(tester).pixels;
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(position(tester).pixels, 0);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      final work = position(tester).pixels;
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(position(tester).pixels, all);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(position(tester).pixels, work);
    });

    testWidgets('clearing search restores the previous offset', (tester) async {
      final s = many();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await tester.pumpAndSettle();
      final before = position(tester).pixels;
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'line');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(position(tester).pixels, 0);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(position(tester).pixels, before);
    });
  });

  group('5,000 notes', () {
    Seed big() {
      final s = freshServices();
      s.services.db.transaction(() {
        for (var i = 0; i < 5000; i++) {
          s.clock.ms += 1000;
          s.services.notes.createNote(
            title: i % 7 == 0 ? '' : 'Synthetic note $i',
            body: paragraphs([
              'First line of synthetic note $i',
              'Second line with a few more words in it',
              'Third line',
            ]),
          );
        }
      });
      return s;
    }

    for (final layout in LibraryLayout.values) {
      testWidgets('$layout builds lazily and scrolls', (tester) async {
        final s = big();
        addTearDown(s.services.close);
        s.services.settings.layout = layout;
        await pumpLibrary(tester, s);
        expect(noteItems().evaluate().length, lessThan(60));
        await tester.fling(
          find.byType(CustomScrollView),
          const Offset(0, -3000),
          6000,
        );
        await tester.pumpAndSettle();
        expect(noteItems().evaluate().length, lessThan(60));
        final pos = scrollPosition(tester);
        expect(pos.pixels, greaterThan(1000));
      });
    }
  });

  testWidgets('animations off: no card or menu transitions run', (
    tester,
  ) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.animations = AnimationLevel.off;
    await pumpLibrary(tester, s);
    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    // With animation off the menu is fully there after a single frame.
    expect(find.text('Settings'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  group('relative date', () {
    final now = DateTime(2026, 11, 17, 14, 30);
    test('formats', () {
      String f(DateTime d) => formatRelativeDate(d, now: now);
      expect(f(now), 'now');
      expect(f(now.subtract(const Duration(minutes: 5))), '5 min');
      expect(f(now.subtract(const Duration(hours: 3))), '3 h');
      expect(f(DateTime(2026, 11, 16, 23, 0)), 'Yesterday');
      expect(f(DateTime(2026, 3, 12)), '12 Mar');
      expect(f(DateTime(2025, 3, 12)), '12 Mar 2025');
      expect(f(now.add(const Duration(minutes: 3))), 'now');
    });
  });

  testWidgets('mouse back button leaves a sub-view', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: const Size(1280, 800));
    await menuTap(tester, 'Archive');
    expect(libraryTitle('Archive'), findsOneWidget);
    final g = await tester.startGesture(
      const Offset(600, 400),
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await g.up();
    await tester.pumpAndSettle();
    expect(libraryTitle('All notes'), findsOneWidget);
    expect(libraryTitle('Archive'), findsNothing);
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.byType(NoteCard), findsWidgets);
  });
}
