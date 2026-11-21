import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/ui/library/desktop_sidebar.dart';
import 'package:notes/ui/material.dart';

import '../../support/screenshot.dart';
import 'support.dart';

Finder _popupMenu() => find.byWidgetPredicate(
  (widget) =>
      widget is Material &&
      widget.type == MaterialType.card &&
      widget.elevation > 0,
);

void main() {
  setUpAll(loadAppFonts);

  testWidgets('phone menu anchors under More and orders destinations first', (
    tester,
  ) async {
    final s = seedLibrary(startupView: StartupView.all);
    addTearDown(s.services.close);
    s.services.notes.setArchived([s.ids['short']!], true);
    s.services.notes.trash([s.ids['wifi']!]);
    markConflict(s, 'ideas');
    await pumpLibrary(tester, s);

    final more = find.byTooltip('More');
    final search = find.byTooltip('Search');
    final moreRect = tester.getRect(more);
    expect(moreRect.size, const Size(48, 48));
    expect(tester.getCenter(more).dy, tester.getCenter(search).dy);
    await openMenu(tester);

    final popup = _popupMenu().last;
    final popupRect = tester.getRect(popup);
    final screenWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(popupRect.top, greaterThanOrEqualTo(moreRect.bottom));
    expect(popupRect.width, inInclusiveRange(224, 288));
    expect(
      popupRect.right,
      closeTo(math.min(moreRect.right, screenWidth - 8), 1),
    );

    Finder item(String label) =>
        find.descendant(of: popup, matching: find.text(label));
    double top(String label) => tester.getTopLeft(item(label).first).dy;
    expect(item('All notes'), findsNothing);
    expect(top('Archive'), lessThan(top('Trash')));
    expect(top('Trash'), lessThan(top('Conflicts')));
    expect(top('Conflicts'), lessThan(top('View')));
    expect(top('View'), lessThan(tester.getTopLeft(find.byTooltip('Grid')).dy));
    expect(
      tester.getTopLeft(find.byTooltip('Grid')).dy,
      lessThan(top('Sort by')),
    );
    expect(top('Sort by'), lessThan(top('Modified')));
    expect(top('Title'), lessThan(top('Settings')));
    expect(item('1'), findsNWidgets(3));
    expect(item('Empty Trash'), findsNothing);
  });

  testWidgets('layout toggles expose selected button semantics and close', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.layout = LibraryLayout.masonry;
    await pumpLibrary(tester, s);
    await openMenu(tester);

    for (final label in ['Grid', 'Masonry', 'List']) {
      final control = find.byTooltip(label);
      final size = tester.getSize(control);
      expect(size.width, greaterThanOrEqualTo(48), reason: label);
      expect(size.height, greaterThanOrEqualTo(48), reason: label);
      final data = tester.getSemantics(find.bySemanticsLabel(label));
      expect(data.label, label);
      expect(data.flagsCollection.isButton, isTrue);
      expect(
        data.flagsCollection.isSelected == Tristate.isTrue,
        label == 'Masonry',
        reason: label,
      );
    }

    await tester.tap(find.byTooltip('Grid'));
    await tester.pumpAndSettle();
    expect(s.services.settings.layout, LibraryLayout.grid);
    expect(find.text('Settings'), findsNothing);
    expect(find.byTooltip('More'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('Empty Trash is a separated action only inside Trash', (
    tester,
  ) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s);
    await openMenu(tester);
    expect(find.text('Empty Trash'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    s.services.notes.trash([s.ids['wifi']!]);
    await tester.pumpAndSettle();
    await menuTap(tester, 'Trash');
    await openMenu(tester);

    final popup = _popupMenu().last;
    Finder item(String label) =>
        find.descendant(of: popup, matching: find.text(label));
    expect(item('All notes'), findsOneWidget);
    expect(item('Empty Trash'), findsOneWidget);
    expect(item('View'), findsOneWidget);
    expect(
      tester.getTopLeft(item('Empty Trash')).dy,
      lessThan(tester.getTopLeft(item('View')).dy),
    );
  });

  testWidgets('landscape 915x412 at text scale 1.4 scrolls without overflow', (
    tester,
  ) async {
    final s = seedLibrary(startupView: StartupView.all);
    addTearDown(s.services.close);
    s.services.settings.textScale = 1.4;
    markConflict(s, 'ideas');
    await pumpLibrary(tester, s, size: const Size(915, 412));
    final moreRect = tester.getRect(find.byTooltip('More'));
    await openMenu(tester);

    final popup = _popupMenu().last;
    final popupRect = tester.getRect(popup);
    expect(popupRect.top, greaterThanOrEqualTo(moreRect.bottom));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: popup, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.drag(find.text('Modified'), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop overflow stays view-only and anchors under More', (
    tester,
  ) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: const Size(1280, 800));
    expect(find.byType(DesktopSidebar), findsOneWidget);
    final moreRect = tester.getRect(find.byTooltip('More'));
    await openMenu(tester);

    final popup = _popupMenu().last;
    final popupRect = tester.getRect(popup);
    expect(popupRect.top, greaterThanOrEqualTo(moreRect.bottom));
    Finder item(String label) =>
        find.descendant(of: popup, matching: find.text(label));
    expect(item('View'), findsOneWidget);
    expect(item('Settings'), findsNothing);
    expect(item('Archive'), findsNothing);
    expect(item('Trash'), findsNothing);
    expect(item('Conflicts'), findsNothing);
    expect(item('Empty Trash'), findsNothing);
    expect(find.byTooltip('Grid'), findsOneWidget);
    expect(find.byTooltip('Masonry'), findsOneWidget);
    expect(find.byTooltip('List'), findsOneWidget);
  });
}
