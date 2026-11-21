import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/ui/library/note_card.dart';
import 'package:notes/ui/library/desktop_sidebar.dart';
import 'package:notes/ui/material.dart';

import '../../support/screenshot.dart';
import 'support.dart';

/// Android controls must be at least 48 dp; the Linux layout stays compact.
void main() {
  setUpAll(loadAppFonts);

  Future<void> asPlatform(WidgetTester tester, TargetPlatform p) async {
    debugDefaultTargetPlatformOverride = p;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  Size sizeOf(WidgetTester tester, Finder f) => tester.getSize(f.first);

  Finder chip(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(InkWell));

  testWidgets('Android: header, chips, menu and rows are 48 dp or more', (
    tester,
  ) async {
    await asPlatform(tester, TargetPlatform.android);
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.layout = LibraryLayout.list;
    s.services.settings.previewLines = 0;
    s.services.notes.createNote(title: 'Solo', body: paragraphs(['']));
    await pumpLibrary(tester, s);
    await tester.pumpAndSettle();

    for (final tip in ['Search', 'More']) {
      final size = sizeOf(tester, find.byTooltip(tip));
      expect(size.shortestSide, greaterThanOrEqualTo(48), reason: tip);
    }
    expect(sizeOf(tester, chip('Home')).height, greaterThanOrEqualTo(48));
    // The "new folder" chip is only an icon.
    await tester.drag(find.text('Unfiled'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    final add = sizeOf(tester, find.byTooltip('New folder'));
    expect(add.width, greaterThanOrEqualTo(48));
    expect(add.height, greaterThanOrEqualTo(48));
    // A one-line row is no shorter than a finger.
    final solo = find.ancestor(
      of: find.text('Solo'),
      matching: find.byType(NoteRow),
    );
    expect(sizeOf(tester, solo).height, greaterThanOrEqualTo(48));

    await openMenu(tester);
    final item = find.ancestor(
      of: find.text('Grid'),
      matching: find.byType(InkWell),
    );
    expect(sizeOf(tester, item).height, greaterThanOrEqualTo(48));
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Solo'));
    await tester.pumpAndSettle();
    for (final tip in ['Clear selection', 'Select all', 'Move to Trash']) {
      final size = sizeOf(tester, find.byTooltip(tip));
      expect(size.shortestSide, greaterThanOrEqualTo(48), reason: tip);
    }
  });

  testWidgets('Android: search clear button is a 48 dp target', (tester) async {
    await asPlatform(tester, TargetPlatform.android);
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s);
    await tapTip(tester, 'Search');
    await tester.enterText(find.byType(TextField), 'the');
    await tester.pump();
    final size = sizeOf(tester, find.byTooltip('Clear search'));
    expect(size.shortestSide, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Linux: controls keep their compact size', (tester) async {
    await asPlatform(tester, TargetPlatform.linux);
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.layout = LibraryLayout.list;
    s.services.settings.previewLines = 0;
    s.services.notes.createNote(title: 'Solo', body: paragraphs(['']));
    await pumpLibrary(tester, s, size: const Size(1280, 800));
    expect(tester.takeException(), isNull);
    // A one-line row keeps its natural height with a mouse.
    final solo = find.ancestor(
      of: find.text('Solo'),
      matching: find.byType(NoteRow),
    );
    expect(sizeOf(tester, solo).height, lessThan(48));
    expect(sizeOf(tester, find.byTooltip('More')), const Size(40, 40));
    // Desktop sidebar: 36 dp rows, 28 dp add-folder button.
    final home = find.descendant(
      of: find.byType(DesktopSidebar),
      matching: find.ancestor(
        of: find.text('Home'),
        matching: find.byType(InkWell),
      ),
    );
    expect(sizeOf(tester, home).height, 36);
    expect(sizeOf(tester, find.byTooltip('New folder')).width, 28);
    await openMenu(tester);
    final item = find.ancestor(
      of: find.text('Grid'),
      matching: find.byType(InkWell),
    );
    expect(sizeOf(tester, item).height, 42);
  });
}
