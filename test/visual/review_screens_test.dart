import 'dart:io';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
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

  Future<AppServices> openReadme(
    WidgetTester tester,
    Size size,
    AppTheme theme,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    services.settings.startupView = StartupView.all;
    services.settings.theme = theme;

    final projects = services.notes.createFolder('Projects');
    final personal = services.notes.createFolder('Personal');
    final reading = services.notes.createFolder('Reading');
    final roadmap = services.notes.createNote(
      title: 'Quarter roadmap',
      body: paragraphs([
        'Set goals for the next release',
        'Review offline sync',
        'Update the help guide',
      ]),
      folderId: projects.id,
    );
    services.notes.setPinned([roadmap.id], true);
    services.notes.createNote(
      title: 'Desktop polish',
      body: paragraphs([
        'Check the sidebar at narrow sizes',
        'Review editor shortcuts',
      ]),
      folderId: projects.id,
    );
    services.notes.createNote(
      title: 'Weekend list',
      body: checklistBody([
        ('Try a new recipe', false),
        ('Read a few chapters', false),
        ('Take a long walk', false),
      ]),
      folderId: personal.id,
    );
    services.notes.createNote(
      title: 'Reading list',
      body: paragraphs([
        'A pattern language',
        'The design of everyday things',
        'Working in public',
      ]),
      folderId: reading.id,
    );
    services.notes.createNote(
      title: 'Meeting notes',
      body: paragraphs([
        'Keep the library easy to scan.',
        'Share the updated plan on Friday.',
      ]),
      folderId: projects.id,
    );

    await setWindow(tester, size, pixelRatio: 1);
    await pumpApp(tester, services);
    await tester.pumpAndSettle();
    return services;
  }

  Future<void> readmeShot(
    WidgetTester tester,
    String buildName,
    String fileName,
  ) async {
    await shot(tester, buildName);
    final target = File('docs/screenshots/$fileName')
      ..parent.createSync(recursive: true);
    File('build/screens/$buildName.png').copySync(target.path);
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

  for (final theme in [AppTheme.light, AppTheme.charcoal]) {
    testWidgets('README desktop screenshots ${theme.name}', (tester) async {
      await openReadme(tester, const Size(1440, 900), theme);
      final suffix = theme == AppTheme.light ? 'light' : 'charcoal';
      await readmeShot(
        tester,
        'readme_desktop_library_$suffix',
        'desktop-library-$suffix.png',
      );
      await openNote(tester, 'Quarter roadmap');
      await readmeShot(
        tester,
        'readme_desktop_editor_$suffix',
        'desktop-editor-$suffix.png',
      );
    });

    testWidgets('README phone screenshots ${theme.name}', (tester) async {
      await openReadme(tester, const Size(412, 915), theme);
      final suffix = theme == AppTheme.light ? 'light' : 'charcoal';
      await readmeShot(
        tester,
        'readme_phone_library_$suffix',
        'phone-library-$suffix.png',
      );
      await openNote(tester, 'Quarter roadmap');
      await readmeShot(
        tester,
        'readme_phone_editor_$suffix',
        'phone-editor-$suffix.png',
      );
    });
  }
}
