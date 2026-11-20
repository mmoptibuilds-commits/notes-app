import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ui/data/data_screen.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/help/help_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/settings/settings_screen.dart';
import 'package:notes/ui/settings/toolbar_settings_screen.dart';

import '../../support/screenshot.dart';
import 'support.dart';

/// Escape must dismiss the topmost transient thing first (popup menu, dialog,
/// sheet), then go back exactly one level, and do nothing at the root.
void main() {
  setUpAll(loadAppFonts);

  const desktop = Size(1280, 800);

  Future<void> esc(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  Future<void> ctrlF(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> click(WidgetTester tester, Finder f) async {
    await tester.tapAt(
      tester.getCenter(f.first),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, Finder f) async {
    final g = await tester.startGesture(
      tester.getCenter(f.first),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await g.up();
    await tester.pumpAndSettle();
  }

  final popup = find.byWidgetPredicate((w) => w is PopupMenuItem);
  bool searchFocused(WidgetTester tester) => tester
      .widget<EditableText>(find.byType(EditableText).first)
      .focusNode
      .hasFocus;

  Future<Seed> open(WidgetTester tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: desktop);
    return s;
  }

  Future<void> scrollTo(WidgetTester tester, String text) async {
    // Back to the top first: rows are built lazily and may be above.
    await tester.fling(
      find.byType(ListView).first,
      const Offset(0, 5000),
      5000,
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(text),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  group('library popups', () {
    testWidgets('overflow (and sort) menu: Escape closes it, repeatedly', (
      tester,
    ) async {
      await open(tester);
      for (var round = 0; round < 3; round++) {
        await openMenu(tester);
        expect(popup, findsWidgets, reason: 'menu open, round $round');
        expect(find.text('Sort by'), findsOneWidget);
        await esc(tester);
        expect(popup, findsNothing, reason: 'Escape closes, round $round');
        expect(find.byType(FloatingActionButton), findsOneWidget);
        await esc(tester); // nothing left to do at the root: stays put
        expect(find.byType(FloatingActionButton), findsOneWidget);
      }
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue, reason: 'shortcuts still work');
    });

    testWidgets('folder context menu: Escape closes it', (tester) async {
      await open(tester);
      await rightClick(tester, find.text('Work'));
      expect(popup, findsWidgets);
      await esc(tester);
      expect(popup, findsNothing);
      expect(find.text('Work'), findsWidgets);
      await rightClick(tester, find.text('Work'));
      expect(popup, findsWidgets, reason: 'can reopen');
      await esc(tester);
      expect(popup, findsNothing);
    });

    testWidgets('note context menu: Escape closes it, selection stays sane', (
      tester,
    ) async {
      await open(tester);
      await rightClick(tester, find.text('Passport'));
      expect(popup, findsWidgets);
      await esc(tester);
      expect(popup, findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('Trash: Escape closes a menu first, then goes back one level', (
      tester,
    ) async {
      final s = await open(tester);
      s.services.notes.trash([s.ids['short']!]);
      await menuTap(tester, 'Trash');
      expect(find.byType(FloatingActionButton), findsNothing);
      await openMenu(tester);
      await esc(tester);
      expect(popup, findsNothing);
      expect(
        find.byType(FloatingActionButton),
        findsNothing,
        reason: 'still in Trash',
      );
      await esc(tester);
      expect(
        find.byType(FloatingActionButton),
        findsOneWidget,
        reason: 'back to notes',
      );
    });
  });

  group('mouse-driven sub-views', () {
    Future<void> mouseMenuTap(WidgetTester tester, String label) async {
      await click(tester, find.byTooltip('More'));
      await click(tester, find.text(label));
    }

    for (final view in ['Trash', 'Archive']) {
      testWidgets('$view opened with the mouse: Escape goes back, then stays', (
        tester,
      ) async {
        final s = await open(tester);
        s.services.notes.trash([s.ids['short']!]);
        s.services.notes.setArchived([s.ids['wifi']!], true);
        await mouseMenuTap(tester, view);
        expect(find.byType(FloatingActionButton), findsNothing);
        await esc(tester);
        expect(find.byType(FloatingActionButton), findsOneWidget);
        await esc(tester); // root: nothing more to do, the app stays
        expect(find.byType(FloatingActionButton), findsOneWidget);
        await mouseMenuTap(tester, view); // and it can be opened again
        await esc(tester);
        expect(find.byType(FloatingActionButton), findsOneWidget);
      });
    }

    testWidgets('Settings opened from the menu with the mouse: Escape back', (
      tester,
    ) async {
      await open(tester);
      await mouseMenuTap(tester, 'Settings');
      expect(find.byType(SettingsScreen), findsOneWidget);
      await esc(tester);
      expect(find.byType(SettingsScreen), findsNothing);
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
    });

    testWidgets('a menu opened, dismissed with a click away, then Escape', (
      tester,
    ) async {
      await open(tester);
      await click(tester, find.byTooltip('More'));
      expect(popup, findsWidgets);
      await tester.tapAt(const Offset(10, 700), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
      await ctrlF(tester);
      expect(searchFocused(tester), isTrue);
      await esc(tester);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });

  group('secondary screens', () {
    testWidgets('Settings pages: Escape returns exactly one level', (
      tester,
    ) async {
      await open(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      // (The Sync and Pair screens use the same wrapper, but the in-memory
      // test services have no sync service, so Settings does not list them.)
      final pages = <(String, Type)>[
        ('Customise toolbar', ToolbarSettingsScreen),
        ('Import and export', DataScreen),
      ];
      for (final (label, type) in pages) {
        await scrollTo(tester, label);
        await click(tester, find.text(label));
        expect(find.byType(type), findsOneWidget, reason: label);
        await esc(tester);
        expect(
          find.byType(type),
          findsNothing,
          reason: '$label: Escape goes back',
        );
        expect(
          find.byType(SettingsScreen),
          findsOneWidget,
          reason: '$label: one level only',
        );
      }
      await esc(tester);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('Settings dropdown: Escape closes it, Settings stays', (
      tester,
    ) async {
      await open(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await click(tester, find.byTooltip('Interface font'));
      expect(popup, findsWidgets);
      await esc(tester);
      expect(popup, findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await esc(tester);
      expect(find.byType(SettingsScreen), findsNothing);
    });

    testWidgets('Help: Escape goes back one level, from Settings or library', (
      tester,
    ) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(find.byType(HelpScreen), findsOneWidget);
      await esc(tester);
      expect(find.byType(HelpScreen), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });

  group('editor', () {
    Future<void> newNote(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsOneWidget);
    }

    testWidgets(
      'toolbar-area menu with Quill focused: Escape closes the menu, not the note',
      (tester) async {
        await open(tester);
        await newNote(tester);
        await click(tester, find.byTooltip('More'));
        expect(popup, findsWidgets);
        await esc(tester);
        expect(popup, findsNothing);
        expect(
          find.byType(EditorScreen),
          findsOneWidget,
          reason: 'note stays open',
        );
        await esc(tester); // the editor's normal back behaviour
        expect(find.byType(EditorScreen), findsNothing);
        expect(find.byType(FloatingActionButton), findsOneWidget);
      },
    );

    testWidgets('editor dialog and sheet: Escape closes only that layer', (
      tester,
    ) async {
      await open(tester);
      await newNote(tester);
      await click(tester, find.byTooltip('More'));
      await click(tester, find.text('Move to folder…'));
      expect(find.byType(BottomSheet), findsOneWidget);
      await esc(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(EditorScreen), findsOneWidget);
      await click(tester, find.byTooltip('Link'));
      expect(find.byType(AlertDialog), findsOneWidget);
      await esc(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(EditorScreen), findsOneWidget);
      await esc(tester);
      expect(find.byType(EditorScreen), findsNothing);
    });
  });
}
