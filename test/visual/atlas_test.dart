import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/onboarding/onboarding_screen.dart';
import 'package:notes/ui/splash.dart';
import 'package:notes/ui/startup_error.dart';
import 'package:notes/ui/sync/pair_screen.dart';
import 'package:notes/ui/sync/sync_screen.dart';
import 'package:notes/ui/theme/app_theme.dart';
import 'package:notes/ui/updates/updates_screen.dart';
import 'package:notes/sync/peers.dart';
import 'package:notes/sync/sync_service.dart';

import '../support/screenshot.dart';
import '../ui/library/support.dart';
import '../update/fake_http.dart';
import '../update/world.dart';

const _forms = <String, Size>{
  'phone': Size(412, 915),
  'phone-landscape': Size(915, 412),
  'tablet': Size(800, 1280),
  'desktop-small': Size(1024, 700),
  'desktop': Size(1440, 900),
  'desktop-wide': Size(1920, 1080),
};

final _index = <String, String>{};

String _themeName(AppTheme theme) => switch (theme) {
  AppTheme.amoled => 'amoled',
  AppTheme.charcoal => 'charcoal',
  AppTheme.light => 'light',
};

Future<void> _capture(
  WidgetTester tester,
  String form,
  AppTheme theme,
  String name,
  String description,
) async {
  final path = 'build/screens/atlas/$form/${_themeName(theme)}/$name.png';
  await screenshot(tester, name, path: path);
  _index['$form/${_themeName(theme)}/$name.png'] = description;
}

Future<Seed> _library(
  WidgetTester tester, {
  required String form,
  required AppTheme theme,
  bool largeText = false,
  bool empty = false,
}) async {
  final seed = empty
      ? freshServices()
      : seedLibrary(startupView: StartupView.unfiled);
  addTearDown(seed.services.close);
  seed.services.settings.theme = theme;
  if (largeText) seed.services.settings.textScale = 1.4;
  final size = _forms[form]!;
  final double ratio = form == 'phone'
      ? 2.625
      : (form == 'phone-landscape' ? 2 : 1);
  await setWindow(tester, size, pixelRatio: ratio);
  await pumpApp(tester, seed.services);
  await tester.pumpAndSettle();
  return seed;
}

Future<void> _writeIndex() async {
  final file = File('build/screens/atlas/INDEX.md')
    ..createSync(recursive: true);
  final lines = <String>[
    '# Screen atlas',
    '',
    'Rendered PNGs use synthetic in-memory notes. Paths are relative to this directory.',
    '',
    '| File | State |',
    '|---|---|',
    for (final path in (_index.keys.toList()..sort()))
      '| `$path` | ${_index[path]} |',
    '',
    'Not captured: Android-only camera scan tab; native permission and platform update installer prompts; OS file chooser; transient network/installer failures; editor conflict banner; expanded completed-items section; snackbar/undo state; shortcuts settings page; toolbar popovers beyond the link dialog.',
  ];
  file.writeAsStringSync(lines.join('\n'));
}

Delta _richBody() => Delta()
  ..insert('A field guide to quiet mornings')
  ..insert('\n', {'header': 1})
  ..insert('Start with one small thing.\n')
  ..insert('Write the first paragraph')
  ..insert('\n', {'list': 'unchecked'})
  ..insert('Make coffee')
  ..insert('\n', {'list': 'checked'})
  ..insert('A useful thought to keep nearby')
  ..insert('\n', {'blockquote': true})
  ..insert('final total = 42;')
  ..insert('\n', {'code-block': true})
  ..insert('Read more', {'link': 'https://example.org'})
  ..insert('\n');

Future<AppServices> _servicesWithSync() async {
  final base = AppServices.inMemory();
  final identity = await DeviceIdentity.loadOrCreate(base.db);
  final sync = SyncService(
    repo: base.notes,
    peers: PeerStore(base.db),
    identity: identity,
    deviceName: base.settings.deviceName,
    port: 0,
    bindAddress: InternetAddress.loopbackIPv4,
    enableDiscovery: false,
    localAddresses: () async => ['192.168.1.20'],
  );
  return AppServices(base.db, base.notes, base.settings, '', sync: sync);
}

void main() {
  setUpAll(loadAppFonts);
  tearDownAll(_writeIndex);

  for (final entry in _forms.entries) {
    final fullThemes =
        entry.key == 'phone' ||
        entry.key == 'desktop' ||
        entry.key == 'desktop-wide';
    final themes = fullThemes ? AppTheme.values : const [AppTheme.charcoal];
    for (final theme in themes) {
      testWidgets('${entry.key} ${_themeName(theme)} library layouts', (
        tester,
      ) async {
        final seed = await _library(
          tester,
          form: entry.key,
          theme: theme,
          largeText: fullThemes && theme == AppTheme.amoled,
        );
        for (final layout in LibraryLayout.values) {
          seed.services.settings.layout = layout;
          await tester.pumpAndSettle();
          await _capture(
            tester,
            entry.key,
            theme,
            '01-library-${layout.name}',
            'Unfiled home in ${layout.name} layout${fullThemes && theme == AppTheme.amoled ? ', text scale 1.4' : ''}.',
          );
        }
      });
    }
  }

  for (final form in ['phone', 'desktop']) {
    testWidgets('$form empty Unfiled home', (tester) async {
      final seed = freshServices();
      addTearDown(seed.services.close);
      seed.services.notes.createFolder('Work');
      seed.services.settings.theme = AppTheme.amoled;
      final ratio = form == 'phone' ? 2.625 : 1.0;
      await setWindow(tester, _forms[form]!, pixelRatio: ratio);
      await pumpApp(tester, seed.services);
      await tester.pumpAndSettle();

      expect(seed.services.settings.startupView, StartupView.unfiled);
      expect(libraryTitle('Unfiled'), findsOneWidget);
      expect(find.text('No unfiled notes yet.'), findsOneWidget);
      expect(
        find.text(
          form == 'phone'
              ? 'Tap + to write one.'
              : 'Choose New note to write one.',
        ),
        findsOneWidget,
      );
      await _capture(
        tester,
        form,
        AppTheme.amoled,
        '00-unfiled-empty',
        'Unfiled home with no unfiled notes and one empty folder.',
      );
    });
  }

  testWidgets('phone library scopes menus and dialogs', (tester) async {
    final s = await _library(tester, form: 'phone', theme: AppTheme.charcoal);
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '02-library',
      'Unfiled home with folders, pinned notes and checklists.',
    );

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '03-folder-home',
      'Home folder contents.',
    );
    await tester.tap(find.text('Unfiled'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '04-unfiled',
      'Unfiled notes.',
    );

    s.services.notes.setArchived([s.ids['short']!], true);
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    s.services.notes.trash([s.ids['wifi']!]);
    await tester.pumpAndSettle();
    await menuTap(tester, 'Archive');
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '05-archive',
      'Archive scope.',
    );
    await menuTap(tester, 'Trash');
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '06-trash',
      'Trash scope.',
    );
    await tester.tap(find.text('Wifi'), buttons: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '06a-delete-forever-confirmation',
      'Confirmation dialog for permanently deleting a trashed note.',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('Empty Trash'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '06b-empty-trash-confirmation',
      'Confirmation dialog for emptying Trash.',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await menuTap(tester, 'All notes');
    markConflict(s, 'ideas');
    await tester.pumpAndSettle();
    await menuTap(tester, 'Conflicts');
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '07-conflicts',
      'Conflicts scope with a synthetic conflict copy.',
    );
    await menuTap(tester, 'All notes');

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'road');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '08-search-results',
      'Active search with matching results.',
    );
    await tester.enterText(find.byType(TextField), 'no-match-xyz');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '09-search-empty',
      'Active search with no results.',
    );
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Groceries'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quarter roadmap'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '10-multi-select',
      'Multi-select mode with bulk action bar.',
    );
    await tester.tap(find.byTooltip('Clear selection'));
    await tester.pumpAndSettle();

    await openMenu(tester);
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '11-overflow-menu',
      'Library overflow menu open.',
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Work'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '12-folder-context',
      'Folder context menu open.',
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Groceries'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move to folder'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '13-move-dialog',
      'Move-to-folder dialog.',
    );
    await tester.tap(find.textContaining('New folder'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '14-new-folder-dialog',
      'New-folder prompt opened from the move dialog.',
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    if (find.byTooltip('Clear selection').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Clear selection'));
      await tester.pumpAndSettle();
    }

    await tester.longPress(find.text('Groceries'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear selection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'), buttons: 2);
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '15-note-context',
      'Note card context menu open.',
    );
  });

  testWidgets('desktop top menu and editor pane', (tester) async {
    await _library(tester, form: 'desktop', theme: AppTheme.charcoal);
    await openMenu(tester);
    await _capture(
      tester,
      'desktop',
      AppTheme.charcoal,
      '02-overflow-menu',
      'Desktop library overflow menu open.',
    );
    await tester.tapAt(const Offset(400, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'desktop',
      AppTheme.charcoal,
      '03-editor-pane',
      'Desktop editor pane open beside the library.',
    );
  });

  testWidgets('phone landscape overflow menu', (tester) async {
    await _library(
      tester,
      form: 'phone-landscape',
      theme: AppTheme.charcoal,
      largeText: true,
    );
    await openMenu(tester);
    expect(tester.takeException(), isNull);
    await _capture(
      tester,
      'phone-landscape',
      AppTheme.charcoal,
      '11-overflow-menu',
      'Phone library overflow menu open in landscape at text scale 1.4.',
    );
  });

  testWidgets('settings sections and routed pages', (tester) async {
    await _library(tester, form: 'phone', theme: AppTheme.light);
    await openMenu(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '25-settings-appearance',
      'Settings appearance section with theme controls.',
    );

    final list = find.byType(ListView).last;
    await tester.drag(list, const Offset(0, -520));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '26-settings-library-editor',
      'Settings library and editor sections.',
    );
    await tester.ensureVisible(find.text('Customise toolbar'));
    await tester.tap(find.text('Customise toolbar'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '27-toolbar-customization',
      'Editor toolbar customization page.',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    final settingsList = find.byType(ListView).last;
    await tester.drag(settingsList, const Offset(0, -1200));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '28-settings-about-help',
      'Settings sync, data and about sections.',
    );
    await tester.ensureVisible(find.text('Import and export'));
    await tester.tap(find.text('Import and export'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '29-data-import-export',
      'Data import, restore and export screen.',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Help'));
    await tester.tap(find.text('Help').last);
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '30-help',
      'Offline help topics and search.',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Open-source licences'));
    await tester.tap(find.text('Open-source licences'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '31-open-source-licences',
      'Open-source licence acknowledgements.',
    );
  });

  testWidgets('sync screens', (tester) async {
    final s = await _servicesWithSync();
    addTearDown(s.close);
    await setWindow(tester, _forms['phone']!, pixelRatio: 2.625);
    await tester.pumpWidget(
      AppScope(
        services: s,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(s.settings),
          home: const SyncScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '32-sync-empty',
      'Sync screen before a device is paired.',
    );
    s.sync!.peers.add(
      id: newDeviceId(),
      name: 'Atlas desktop',
      publicKey: randomBytes(32),
    );
    s.notes.createNote(title: 'Pending synthetic sync');
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '32a-sync-paired-device',
      'Sync screen with one paired device and local pending changes.',
    );
  });

  testWidgets('pair code and entry screens', (tester) async {
    final s = await _servicesWithSync();
    addTearDown(s.close);
    await setWindow(tester, _forms['phone']!, pixelRatio: 2.625);
    await tester.pumpWidget(
      AppScope(
        services: s,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(s.settings),
          home: const PairScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '33-pair-show-code',
      'Pairing screen showing a synthetic local pairing code.',
    );
    await tester.tap(find.text('Enter code'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '34-pair-enter-code',
      'Pairing screen for entering a code; Android camera scan is unavailable on this test host.',
    );
  });

  testWidgets('updater states with fakes', (tester) async {
    final world = await World.create();
    addTearDown(world.dispose);
    final updateServices = AppServices.inMemory();
    addTearDown(updateServices.close);
    final settings = updateServices.settings;
    final screen = UpdatesScreen(
      controller: world.controller,
      settings: settings,
      clock: () => world.now,
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(settings),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '35-updates-idle',
      'Updates screen before a check.',
    );
    await tester.runAsync(() async {
      await world.publish(version: '1.0.0', build: 20261122);
      await world.controller.check();
    });
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '36-updates-up-to-date',
      'Updater state reports the app is up to date.',
    );
    await tester.runAsync(() async {
      await world.publish();
      await world.controller.check();
    });
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '37-updates-available',
      'Updater state reports an available update.',
    );
    world.installer.gate = Completer<void>();
    await tester.runAsync(() async {
      unawaited(world.controller.download());
    });
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '38-updates-downloading',
      'Updater downloading an available release.',
    );
    world.installer.gate!.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '39-updates-ready-to-install',
      'Updater state has downloaded an update and is ready to install.',
    );
    world.http.on(world.apiUrl, FakeReply(500));
    await tester.runAsync(world.controller.check);
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '40-updates-error',
      'Updater check failure state from the fake HTTP client.',
    );
    world.http.on(world.apiUrl, FakeReply(404));
    await tester.runAsync(world.controller.check);
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.charcoal,
      '41-updates-no-stable-release',
      'Updater reports there is no stable release.',
    );
  });

  testWidgets('editor rich note, completed section and trash banner', (
    tester,
  ) async {
    final seed = await _library(
      tester,
      form: 'phone',
      theme: AppTheme.amoled,
      largeText: true,
    );
    final rich = seed.services.notes.createNote(
      title: 'Morning field notes',
      body: jsonEncode(_richBody().toJson()),
    );
    await tester.pumpWidget(
      AppScope(
        services: seed.services,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(seed.services.settings),
          home: const EditorScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.amoled,
      '16-empty-new-note',
      'Empty new-note editor before any content is entered.',
    );
    await tester.pumpWidget(
      AppScope(
        services: seed.services,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(seed.services.settings),
          home: EditorScreen(noteId: rich.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.amoled,
      '17-editor-rich',
      'Rich editor with heading, paragraphs, checklist, quote, code and link at text scale 1.4.',
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    editor.controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 5),
      ChangeSource.local,
    );
    await tester.pump();
    final toolbar = find.byWidgetPredicate(
      (widget) =>
          widget is ListView && widget.scrollDirection == Axis.horizontal,
    );
    await tester.drag(toolbar.last, const Offset(-900, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Link'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.amoled,
      '17a-link-dialog',
      'Link formatting dialog open for selected editor text.',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    if (find.textContaining('completed').evaluate().isNotEmpty) {
      await tester.tap(find.textContaining('completed').first);
      await tester.pumpAndSettle();
      await _capture(
        tester,
        'phone',
        AppTheme.amoled,
        '18-editor-completed-expanded',
        'Editor completed-items section expanded.',
      );
    }
    await tester.tap(find.byTooltip('More').last);
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.amoled,
      '19-editor-overflow',
      'Editor overflow menu open.',
    );
    await tester.tapAt(const Offset(12, 12));
    await tester.pumpAndSettle();

    seed.services.notes.trash([rich.id]);
    await tester.pumpWidget(
      AppScope(
        services: seed.services,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(seed.services.settings),
          home: EditorScreen(noteId: rich.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.amoled,
      '20-editor-trash-readonly',
      'Read-only trashed note banner.',
    );
  });

  testWidgets('empty state onboarding splash startup and settings root', (
    tester,
  ) async {
    final s = await _library(
      tester,
      form: 'phone',
      theme: AppTheme.light,
      empty: true,
    );
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '20-empty-library',
      'Empty library.',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(s.services.settings),
        home: OnboardingScreen(
          onCreateNote: _noop,
          onImport: _noop,
          onSkip: _noop,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '21-onboarding',
      'First-run welcome screen.',
    );
    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '22-splash',
      'Splash screen.',
    );
    await tester.pumpWidget(
      StartupErrorApp(error: StateError('Synthetic startup error')),
    );
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '23-startup-error',
      'Startup error screen using a synthetic error.',
    );
    await tester.pumpWidget(NotesApp(services: s.services));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await _capture(
      tester,
      'phone',
      AppTheme.light,
      '24-settings-root',
      'Settings root sections.',
    );
  });
}

void _noop() {}
