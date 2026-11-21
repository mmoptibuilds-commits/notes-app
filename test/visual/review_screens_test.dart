import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/ui/library/note_card.dart';
import 'package:notes/ui/material.dart';

import '../support/screenshot.dart';
import '../ui/library/support.dart';

/// Review artefacts for the desktop shell: PNGs in build/screens/. They only
/// assert that the screens build; a person looks at the images.
void main() {
  setUpAll(loadAppFonts);

  Future<Seed> open(
    WidgetTester tester,
    Size size, {
    AppTheme theme = AppTheme.charcoal,
  }) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.theme = theme;
    await pumpLibrary(tester, s, size: size);
    await tester.pumpAndSettle();
    return s;
  }

  Future<void> openNote(WidgetTester tester, String title) async {
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate((w) => w is NoteCard || w is NoteRow),
        matching: find.text(title),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final theme in AppTheme.values) {
    testWidgets('desktop 1440x900 library ${theme.name}', (tester) async {
      await open(tester, const Size(1440, 900), theme: theme);
      await shot(tester, 'desktop_1440_library_${theme.name}');
    });

    testWidgets('desktop 1440x900 pane ${theme.name}', (tester) async {
      await open(tester, const Size(1440, 900), theme: theme);
      await openNote(tester, 'Groceries');
      await shot(tester, 'desktop_1440_pane_${theme.name}');
    });
  }

  testWidgets('desktop 1024x700', (tester) async {
    await open(tester, const Size(1024, 700));
    await shot(tester, 'desktop_1024_library');
    await openNote(tester, 'Quarter roadmap');
    await shot(tester, 'desktop_1024_pane');
  });

  testWidgets('desktop 900x700 pane', (tester) async {
    await open(tester, const Size(900, 700));
    await openNote(tester, 'Quarter roadmap');
    await shot(tester, 'desktop_900_pane');
  });

  testWidgets('desktop list layout, folder, text scale 1.4', (tester) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    s.services.settings.layout = LibraryLayout.list;
    s.services.settings.textScale = 1.4;
    await pumpLibrary(tester, s, size: const Size(1280, 800));
    await tester.pumpAndSettle();
    await shot(tester, 'desktop_1280_list_scale14');
    await openNote(tester, 'Groceries');
    await shot(tester, 'desktop_1280_pane_scale14');
  });

  testWidgets('desktop new note and Trash', (tester) async {
    final s = await open(tester, const Size(1440, 900));
    s.services.notes.trash([s.ids['short']!]);
    await tester.tap(find.text('Trash'));
    await tester.pumpAndSettle();
    await shot(tester, 'desktop_1440_trash');
    await tester.tap(find.text('New note'));
    await tester.pumpAndSettle();
    expect(find.byType(QuillEditor), findsOneWidget);
    await shot(tester, 'desktop_1440_new_note');
  });

  testWidgets('phone 412x915 library and editor', (tester) async {
    await open(tester, const Size(412, 915));
    await shot(tester, 'phone_412_library');
    await openNote(tester, 'Groceries');
    await shot(tester, 'phone_412_editor');
  });
}
