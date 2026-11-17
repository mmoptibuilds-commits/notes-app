import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/ui/material.dart';

import '../../support/screenshot.dart';
import 'support.dart';

/// Review artefacts: PNGs in build/screens/. They assert only that the
/// screens build; a human looks at the images.
void main() {
  setUpAll(loadAppFonts);

  const phone = Size(412, 915);
  const laptop = Size(1280, 800);
  const fullHd = Size(1920, 1080);

  for (final theme in AppTheme.values) {
    testWidgets('library phone masonry ${theme.name}', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      s.services.settings.theme = theme;
      await pumpLibrary(tester, s, size: phone);
      await tester.pumpAndSettle();
      await shot(tester, 'library_phone_masonry_${theme.name}');
    });
  }

  testWidgets('library phone list and grid', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.layout = LibraryLayout.list;
    await pumpLibrary(tester, s, size: phone);
    await shot(tester, 'library_phone_list');
    s.services.settings.layout = LibraryLayout.grid;
    await tester.pumpAndSettle();
    await shot(tester, 'library_phone_grid');
  });

  testWidgets('library desktop', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: laptop);
    await shot(tester, 'library_desktop_1280_masonry');
    s.services.settings.layout = LibraryLayout.list;
    await tester.pumpAndSettle();
    await shot(tester, 'library_desktop_1280_list');
    s.services.settings.layout = LibraryLayout.grid;
    await tester.pumpAndSettle();
    await shot(tester, 'library_desktop_1280_grid');
  });

  testWidgets('library desktop 1920', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: fullHd);
    await shot(tester, 'library_desktop_1920_masonry');
  });

  testWidgets('selection mode', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.layout = LibraryLayout.grid;
    await pumpLibrary(tester, s, size: phone);
    await selectByLongPress(tester, 'Passport');
    await tester.tap(find.text('Wifi'));
    await tester.pumpAndSettle();
    await shot(tester, 'library_selection');
  });

  testWidgets('search results', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.layout = LibraryLayout.grid;
    await pumpLibrary(tester, s, size: phone);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'the');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    await shot(tester, 'library_search_phone');
  });

  testWidgets('search results desktop', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: laptop);
    await tester.enterText(find.byType(TextField), 'the');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    await shot(tester, 'library_search_desktop');
  });

  testWidgets('trash and conflicts', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.notes.trash([s.ids['short']!, s.ids['wifi']!, s.ids['old']!]);
    markConflict(s, 'ideas');
    await pumpLibrary(tester, s, size: phone);
    await menuTap(tester, 'Trash');
    await shot(tester, 'library_trash');
    await menuTap(tester, 'All notes');
    await openMenu(tester);
    await shot(tester, 'library_menu');
    await tester.tap(find.text('Conflicts'));
    await tester.pumpAndSettle();
    await shot(tester, 'library_conflicts');
  });

  testWidgets('empty state', (tester) async {
    final s = freshServices();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: phone);
    await shot(tester, 'library_empty');
  });

  testWidgets('folder selected, desktop context menu', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: laptop);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'), buttons: 2);
    await tester.pumpAndSettle();
    await shot(tester, 'library_desktop_context_menu');
  });
}
