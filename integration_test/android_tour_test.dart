import 'dart:convert';
import 'dart:io';

import 'package:flutter_quill/flutter_quill.dart' show QuillEditor;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/app.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart'
    show FocusManager, ListView, SizedBox, TextField;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android UI screen tour', (tester) async {
    final dataDir = await Directory.systemTemp.createTemp(
      'notes-android-tour-',
    );
    AppServices? services;
    final captured = <String>[];
    final failures = <String>[];

    addTearDown(() async {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        services?.close();
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (dataDir.existsSync()) await dataDir.delete(recursive: true);
      }
    });

    Future<void> capture(String name) async {
      await settle(tester);
      // The host (tool/android_tour.sh) watches logcat for this marker and
      // takes an `adb screencap` while the app holds still. The integration
      // test screenshot API hangs on some emulators, and screencap also shows
      // the real system bars.
      // ignore: avoid_print
      print('ANDROID_TOUR_SHOT $name');
      final end = DateTime.now().add(const Duration(milliseconds: 2500));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      captured.add(name);
    }

    Future<void> step(String name, Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stack) {
        failures.add(name);
        final clear = find.byTooltip('Clear selection');
        if (clear.evaluate().isNotEmpty) {
          await tester.tap(clear.first);
          await settle(tester);
        }
        // ignore: avoid_print
        print('ANDROID_TOUR_STEP_FAILED $name: $error\n$stack');
      }
    }

    Future<void> shot(String name) => capture(name);

    Future<void> tapText(String label, {int index = 0}) async {
      final finder = find.text(label, findRichText: true);
      expect(finder, findsWidgets, reason: 'Missing text control: $label');
      await tester.ensureVisible(finder.at(index));
      await settle(tester);
      await tester.tap(finder.at(index));
      await settle(tester);
    }

    Future<void> tapTooltip(String label) async {
      final finder = find.byTooltip(label);
      expect(finder, findsOneWidget, reason: 'Missing tooltip: $label');
      await tester.tap(finder);
      await settle(tester);
    }

    Future<void> back() async {
      var backButton = find.byTooltip('Back');
      if (backButton.evaluate().isEmpty) {
        backButton = find.byTooltip('Back to notes');
      }
      if (backButton.evaluate().isNotEmpty) {
        await tester.tap(backButton.first);
      } else {
        // Android's system Back: pops the top route, menu or dialog.
        await tester.binding.handlePopRoute();
      }
      await settle(tester);
    }

    services = await bootstrap(dataDir: dataDir.path);
    services.settings
      ..completeOnboarding()
      ..autoCheckUpdates = false
      ..completedSection = true
      ..completedCollapsed = false;

    final folders = <String, String>{};
    for (final name in ['Work', 'Home', 'Reading']) {
      folders[name] = services.notes.createFolder(name).id;
    }
    String body(List<String> paragraphs) => jsonEncode([
      for (final paragraph in paragraphs) {'insert': '$paragraph\n'},
    ]);
    String checklist(List<(String, bool)> items) => jsonEncode([
      for (final (text, checked) in items) ...[
        {'insert': text},
        {
          'insert': '\n',
          'attributes': {'list': checked ? 'checked' : 'unchecked'},
        },
      ],
    ]);

    final groceries = services.notes.createNote(
      title: 'Groceries',
      body: checklist([
        ('Oat milk', true),
        ('Coffee beans', true),
        ('Lemons', true),
        ('Rye bread', false),
        ('Olive oil', false),
      ]),
      folderId: folders['Home'],
    );
    services.notes.setPinned([groceries.id], true);
    services.notes.createNote(
      title: 'Quarter roadmap',
      body: body([
        'Ship the offline sync pairing flow',
        'Tidy the importer report',
        'Review Android back-button behaviour',
      ]),
      folderId: folders['Work'],
    );
    services.notes.createNote(
      title: 'Meeting notes',
      body: body([
        'A rich note with several paragraphs for editor review.',
        'Second paragraph with useful synthetic content.',
        'Final paragraph to make the page scroll.',
      ]),
      folderId: folders['Work'],
    );
    services.notes.createNote(
      title: 'Reading list',
      body: checklist([
        ('A pattern language', true),
        ('The design of everyday things', false),
        ('Working in public', false),
      ]),
      folderId: folders['Reading'],
    );
    services.notes.createNote(
      title: '',
      body: body(['An untitled note for library coverage.']),
    );
    final trashed = services.notes.createNote(
      title: 'Packing list',
      body: body(['Tent']),
    );
    services.notes.trash([trashed.id]);

    await tester.pumpWidget(NotesApp(services: services));
    await settle(tester);

    await step('library masonry', () async {
      services!.settings.layout = LibraryLayout.masonry;
      await shot('01-library-masonry');
    });
    for (final (layout, name) in [
      (LibraryLayout.grid, '02-library-grid'),
      (LibraryLayout.list, '03-library-list'),
    ]) {
      await step(name, () async {
        services!.settings.layout = layout;
        await shot(name);
      });
    }
    await step('library overflow open', () async {
      await tapTooltip('More');
      await shot('04-library-overflow-open');
      await tester.binding.handlePopRoute();
      await settle(tester);
    });
    await step('folder view', () async {
      await tapText('Work');
      await shot('05-folder-work');
      await tapText('All');
    });
    await step('unfiled view', () async {
      await tapText('Unfiled');
      await shot('06-folder-unfiled');
      await tapText('All');
    });
    await step('folder context menu', () async {
      await tester.longPress(find.text('Work').first);
      await settle(tester);
      await shot('07-folder-long-press-menu');
      await tester.binding.handlePopRoute();
      await settle(tester);
    });
    await step('search results', () async {
      await tapTooltip('Search');
      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Search notes',
      );
      expect(search, findsOneWidget);
      await tester.enterText(search, 'roadmap');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await shot('08-search-results');
      // Hide the keyboard first so the header buttons are hit-testable.
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester);
      for (final tip in ['Clear search', 'Close search']) {
        final b = find.byTooltip(tip);
        if (b.evaluate().isNotEmpty) await tester.tap(b.first);
        await settle(tester);
      }
    });
    await step('multi select bar', () async {
      await tester.longPress(
        find.text('Meeting notes', findRichText: true).first,
      );
      await settle(tester);
      await shot('09-multi-select-actions');
      await tapTooltip('Clear selection');
      await settle(tester);
    });
    await step('move to folder dialog', () async {
      await tester.longPress(
        find.text('Meeting notes', findRichText: true).first,
      );
      await settle(tester);
      // Wide phones show the action inline; narrow ones put it in a menu.
      final inline = find.byTooltip('Move to folder');
      if (inline.evaluate().isNotEmpty) {
        await tester.tap(inline.first);
        await settle(tester);
      } else {
        await tapTooltip('Selection actions');
        await tapText('Move to folder');
      }
      await shot('10-move-to-folder-dialog');
      await tester.binding.handlePopRoute();
      await settle(tester);
      final clear = find.byTooltip('Clear selection');
      if (clear.evaluate().isNotEmpty) await tester.tap(clear);
      await settle(tester);
    });
    await step('editor rich note', () async {
      await tapText('Groceries');
      await shot('11-editor-rich-note');
      await tester.tap(find.byType(QuillEditor));
      await settle(tester);
      await shot('12-editor-keyboard-toolbar');
      await back();
    });
    await step('completed section expanded', () async {
      await tapText('Groceries');
      await shot('13-editor-completed-expanded');
      await back();
    });
    await step('settings top and bottom', () async {
      await tapTooltip('More');
      await tapText('Settings');
      await shot('14-settings-top');
      final lists = find.byType(ListView);
      expect(lists, findsWidgets);
      await tester.drag(lists.last, const Offset(0, -1300));
      await settle(tester);
      await shot('15-settings-bottom');
    });
    await step('toolbar settings page', () async {
      await tester.drag(find.byType(ListView).last, const Offset(0, -800));
      await settle(tester);
      await tapText('Customise toolbar');
      await shot('16-settings-toolbar');
      await back();
    });
    await step('sync screen', () async {
      await tester.drag(find.byType(ListView).last, const Offset(0, -900));
      await settle(tester);
      await tapText('Sync with other devices');
      await shot('17-sync');
      await back();
    });
    await step('data screen', () async {
      await tester.drag(find.byType(ListView).last, const Offset(0, -500));
      await settle(tester);
      await tapText('Import and export');
      await shot('18-data');
      await back();
    });
    await step('help screen', () async {
      await tester.drag(find.byType(ListView).last, const Offset(0, -1100));
      await settle(tester);
      await tapText('Help');
      await shot('19-help');
      await back();
    });
    await step('updates screen', () async {
      await tester.drag(find.byType(ListView).last, const Offset(0, -800));
      await settle(tester);
      await tapText('App updates');
      await shot('20-updates');
      await back();
    });
    await step('open source licences', () async {
      await tester.drag(find.byType(ListView).last, const Offset(0, -900));
      await settle(tester);
      await tapText('Open-source licences');
      await shot('21-open-source-licences');
      await back();
    });
    await step('trash and empty trash confirmation', () async {
      await back();
      await tapTooltip('More');
      await tapText('Trash');
      await shot('22-trash');
      await tapTooltip('More');
      await tapText('Empty Trash');
      await shot('23-empty-trash-confirmation');
      await tester.binding.handlePopRoute();
      await settle(tester);
      await back(); // Trash -> notes
    });
    await step('light library and editor', () async {
      services!.settings.theme = AppTheme.light;
      await shot('24-library-light');
      await tapText('Groceries');
      await shot('25-editor-light');
      await back();
    });
    await step('charcoal library and editor', () async {
      services!.settings.theme = AppTheme.charcoal;
      await shot('26-library-charcoal');
      await tapText('Groceries');
      await shot('27-editor-charcoal');
      await back();
    });
    await step('large text library and editor', () async {
      services!.settings.textScale = 1.4;
      await shot('28-library-large-text');
      await tapText('Groceries');
      await shot('29-editor-large-text');
      await back();
    });

    // ignore: avoid_print
    print('ANDROID_TOUR_CAPTURED_NAMES ${captured.join(', ')}');
    // ignore: avoid_print
    print(
      'ANDROID_TOUR_FAILED_STEPS ${failures.isEmpty ? 'none' : failures.join(', ')}',
    );
    expect(failures, isEmpty, reason: 'Tour steps failed: $failures');
  });
}

/// Pumps until the UI settles or 4 s pass. On a real device a blinking caret
/// or a progress indicator never settles, and pumpAndSettle would wait for
/// minutes.
Future<void> settle(WidgetTester tester) async {
  final end = DateTime.now().add(const Duration(seconds: 4));
  do {
    await tester.pump(const Duration(milliseconds: 100));
  } while (tester.binding.hasScheduledFrame && DateTime.now().isBefore(end));
}
