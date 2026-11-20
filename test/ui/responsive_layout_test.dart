import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/peers.dart';
import 'package:notes/sync/sync_service.dart';
import 'package:notes/ui/data/data_screen.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/help/help_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/settings/settings_widgets.dart';
import 'package:notes/ui/settings/toolbar_settings_screen.dart';
import 'package:notes/ui/sync/pair_screen.dart';
import 'package:notes/ui/sync/sync_screen.dart';
import 'package:notes/ui/theme/app_theme.dart';
import 'package:notes/ui/widgets/dialogs.dart';

import '../support/screenshot.dart';
import 'editor/editor_screen_test.dart' show sample;
import 'library/support.dart';

/// Phone and desktop window sizes (logical px) the layouts must handle.
const _sizes = <Size>[
  Size(320, 640),
  Size(360, 800),
  Size(480, 320),
  Size(600, 800),
  Size(800, 600),
  Size(1024, 400),
  Size(1440, 900),
];

/// System text scales, up to the worst case (system 2.0 x in-app 1.4).
const _scales = <double>[1, 2, 2.8];

/// Wraps [home] like the app does, so settings and text scale apply.
Future<void> _host(WidgetTester tester, AppServices s, Widget home) async {
  await tester.pumpWidget(
    AppScope(
      services: s,
      child: ListenableBuilder(
        listenable: s.settings,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(s.settings),
          home: home,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

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
    localAddresses: () async => ['192.168.1.20', '100.88.1.5'],
  );
  return AppServices(base.db, base.notes, base.settings, '', sync: sync);
}

/// Every built button is at least [touchTarget] tall on phones.
void _expectTouchButtons(WidgetTester tester, String where) {
  final ex = tester.takeException();
  expect(ex, isNull, reason: where);
  for (final type in [IconButton, TextButton, FilledButton, OutlinedButton]) {
    for (final e in find.byType(type).evaluate()) {
      final box = e.renderObject;
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      expect(
        box.size.height,
        greaterThanOrEqualTo(47.5),
        reason: '${e.widget.runtimeType} at $where',
      );
    }
  }
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isEmpty) return;
    await tester.drag(scrollables.first, const Offset(0, -600));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _scrollToTop(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isEmpty) return;
    await tester.drag(scrollables.first, const Offset(0, 900));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// The screens and popups a phone or desktop user reaches, each built the
/// way the app builds it.
final _surfaces = <String, Future<void> Function(WidgetTester, Size)>{
  'settings': (tester, size) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: size);
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await _scrollToEnd(tester);
  },
  'toolbar settings': (tester, size) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    await setWindow(tester, size);
    await _host(tester, s.services, const ToolbarSettingsScreen());
    await tester.pumpAndSettle();
    await _scrollToEnd(tester);
  },
  'sync': (tester, size) async {
    final s = await _servicesWithSync();
    addTearDown(s.close);
    await setWindow(tester, size);
    await _host(tester, s, const SyncScreen());
    await tester.pumpAndSettle();
  },
  'pair': (tester, size) async {
    final s = await _servicesWithSync();
    addTearDown(s.close);
    await setWindow(tester, size);
    await _host(tester, s, const PairScreen());
    await tester.pumpAndSettle();
  },
  'data': (tester, size) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    await setWindow(tester, size);
    await _host(tester, s, const DataScreen());
    await tester.pumpAndSettle();
    await _scrollToEnd(tester);
  },
  'help': (tester, size) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    await setWindow(tester, size);
    await _host(tester, s, const HelpScreen(shortcuts: []));
    await tester.pumpAndSettle();
    await _scrollToEnd(tester);
  },
  'editor': (tester, size) async {
    final s = seedLibrary();
    addTearDown(s.services.close);
    final note = s.services.notes.createNote(
      body: jsonEncode(sample().toJson()),
    );
    await setWindow(tester, size);
    await _host(tester, s.services, EditorScreen(noteId: note.id));
    await tester.pumpAndSettle();
  },
  'confirm dialog': (tester, size) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    await setWindow(tester, size);
    await _host(tester, s, const _DialogHost());
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  },
};

/// Opens the confirm dialog. The trigger is a plain InkWell so the button
/// scan only sees the dialog's own actions.
class _DialogHost extends StatelessWidget {
  const _DialogHost();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: InkWell(
        onTap: () => confirmDialog(
          context,
          title: 'Delete this note?',
          message: 'The note is removed from every paired device.',
          confirmLabel: 'Delete',
          destructive: true,
        ),
        child: const Padding(padding: EdgeInsets.all(16), child: Text('open')),
      ),
    ),
  );
}

void main() {
  setUpAll(loadAppFonts);

  group('every surface, every window size and text scale', () {
    for (final entry in _surfaces.entries) {
      for (final size in _sizes) {
        for (final scale in _scales) {
          testWidgets(
            '${entry.key} ${size.width.toInt()}x${size.height.toInt()} '
            'scale $scale: no overflow, 48 dp buttons on phones',
            (tester) async {
              tester.platformDispatcher.textScaleFactorTestValue = scale;
              addTearDown(tester.platformDispatcher.clearAllTestValues);
              await entry.value(tester, size);
              await tester.pumpAndSettle();
              _expectTouchButtons(tester, entry.key);
            },
          );
        }
      }
    }
  });

  group('touch sizes on Android', () {
    testWidgets('settings controls reach 48 dp', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: const Size(360, 800));
      await tester.pumpAndSettle();
      await openMenu(tester);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      Size sizeOf(Finder f) => tester.getSize(f.first);
      final segmented = find.byWidgetPredicate(
        (w) => w.runtimeType.toString().startsWith('Segmented<'),
      );
      expect(sizeOf(segmented).height, greaterThanOrEqualTo(47.5));
      expect(sizeOf(find.byType(Slider)).height, greaterThanOrEqualTo(47.5));
      final rows = find.byType(SettingsRow);
      for (final e in rows.evaluate()) {
        final box = e.renderObject! as RenderBox;
        expect(box.size.height, greaterThanOrEqualTo(47.5), reason: 'row');
      }
    });

    testWidgets('sync buttons and rename icon reach 48 dp', (tester) async {
      final s = await _servicesWithSync();
      addTearDown(s.close);
      await setWindow(tester, const Size(1024, 700));
      await _host(tester, s, const SyncScreen());
      await tester.pumpAndSettle();
      _expectTouchButtons(tester, 'sync');
    });

    testWidgets('pairing buttons reach 48 dp', (tester) async {
      final s = await _servicesWithSync();
      addTearDown(s.close);
      await setWindow(tester, const Size(412, 915));
      await _host(tester, s, const PairScreen());
      await tester.pumpAndSettle();
      _expectTouchButtons(tester, 'pair');
    });

    testWidgets('dialog actions reach 48 dp', (tester) async {
      final s = AppServices.inMemory();
      addTearDown(s.close);
      await setWindow(tester, const Size(412, 915));
      await _host(tester, s, const _DialogHost());
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      _expectTouchButtons(tester, 'dialog');
    });

    testWidgets('toolbar reset button reaches 48 dp', (tester) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await setWindow(tester, const Size(412, 915));
      await _host(tester, s.services, const ToolbarSettingsScreen());
      await tester.pumpAndSettle();
      _expectTouchButtons(tester, 'toolbar');
    });
  });

  testWidgets('Linux keeps the compact desktop control sizes', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final s = seedLibrary();
    addTearDown(s.services.close);
    await pumpLibrary(tester, s, size: const Size(1280, 800));
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final segmented = find.byWidgetPredicate(
      (w) => w.runtimeType.toString().startsWith('Segmented<'),
    );
    expect(tester.getSize(segmented.first).height, 40);
    expect(tester.getSize(find.byType(Slider).first).height, 32);
  });

  group('sync buttons', () {
    testWidgets('stack full width on a narrow window', (tester) async {
      final s = await _servicesWithSync();
      addTearDown(s.close);
      await setWindow(tester, const Size(320, 640));
      await _host(tester, s, const SyncScreen());
      await tester.pumpAndSettle();
      final sync = tester.getRect(
        find.widgetWithText(FilledButton, 'Sync now'),
      );
      final pair = tester.getRect(
        find.widgetWithText(OutlinedButton, 'Pair a device'),
      );
      expect(pair.top, greaterThan(sync.bottom), reason: 'stacked');
      expect(sync.width, closeTo(pair.width, 0.5));
      expect(pair.width, greaterThan(250), reason: 'full width');
      // One line of label: the button keeps its single-line height.
      expect(pair.height, lessThan(64));
    });

    testWidgets('sit side by side on a wide window', (tester) async {
      final s = await _servicesWithSync();
      addTearDown(s.close);
      await setWindow(tester, const Size(1024, 700));
      await _host(tester, s, const SyncScreen());
      await tester.pumpAndSettle();
      final sync = tester.getRect(
        find.widgetWithText(FilledButton, 'Sync now'),
      );
      final pair = tester.getRect(
        find.widgetWithText(OutlinedButton, 'Pair a device'),
      );
      expect(pair.left, greaterThan(sync.right));
      expect(pair.top, closeTo(sync.top, 0.5));
    });
  });

  group('selection bar', () {
    Future<void> selectFirst(WidgetTester tester, Size size) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: size);
      await tester.pumpAndSettle();
      await _scrollToTop(tester);
      await tester.longPress(noteItems().first);
      await tester.pumpAndSettle();
    }

    testWidgets('narrow: count stays readable and actions move to a menu', (
      tester,
    ) async {
      await selectFirst(tester, const Size(320, 640));
      expect(tester.takeException(), isNull);
      // The count must fit: its label box is at least its text width.
      final label = find.text('1 selected');
      final text = tester.widget<Text>(label);
      final painter = TextPainter(
        text: TextSpan(text: '1 selected', style: text.style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(tester.element(label)),
      )..layout();
      expect(
        tester.getSize(label).width,
        greaterThanOrEqualTo(painter.width - 0.5),
        reason: 'count truncated',
      );
      expect(find.byTooltip('Selection actions'), findsOneWidget);
      await tester.tap(find.byTooltip('Selection actions'));
      await tester.pumpAndSettle();
      expect(find.text('Move to folder'), findsOneWidget);
      expect(find.text('Move to Trash'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });

    testWidgets('wide: every action is shown inline', (tester) async {
      await selectFirst(tester, const Size(412, 915));
      expect(find.byTooltip('Selection actions'), findsNothing);
      expect(find.byTooltip('Move to folder'), findsOneWidget);
      expect(find.byTooltip('Move to Trash'), findsOneWidget);
    });
  });

  group('live resizing keeps state', () {
    testWidgets('library selection survives 1440 -> 320 -> 1440', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: const Size(1440, 900));
      await tester.pumpAndSettle();
      await _scrollToTop(tester);
      await tester.longPress(noteItems().first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      for (final w in [320.0, 1440.0]) {
        await setWindow(tester, Size(w, 800));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'width $w');
        expect(find.text('1 selected'), findsOneWidget, reason: 'width $w');
      }
      expect(find.byTooltip('Move to folder'), findsOneWidget);
    });

    testWidgets('library search text survives crossing the breakpoint', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      await pumpLibrary(tester, s, size: const Size(412, 915));
      await tester.pumpAndSettle();
      await tapTip(tester, 'Search');
      await tester.enterText(find.byType(TextField), 'the');
      await tester.pumpAndSettle();

      await setWindow(tester, const Size(1000, 800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'the',
      );
    });

    testWidgets('sync buttons re-lay out when the window widens and narrows', (
      tester,
    ) async {
      final s = await _servicesWithSync();
      addTearDown(s.close);
      await setWindow(tester, const Size(1024, 700));
      await _host(tester, s, const SyncScreen());
      await tester.pumpAndSettle();
      Rect pairRect() =>
          tester.getRect(find.widgetWithText(OutlinedButton, 'Pair a device'));
      final wide = pairRect();
      expect(wide.width, lessThan(600));

      await setWindow(tester, const Size(320, 640));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(pairRect().width, greaterThan(250));

      await setWindow(tester, const Size(1024, 700));
      await tester.pumpAndSettle();
      expect(pairRect().width, closeTo(wide.width, 0.5));
    });
  });
}
