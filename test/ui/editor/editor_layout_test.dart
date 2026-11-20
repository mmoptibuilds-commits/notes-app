import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/editor/editor_session.dart';
import 'package:notes/ui/material.dart';

import '../../support/screenshot.dart';
import 'editor_screen_test.dart' show pumpEditor, sample;

String longBody() => bodyFromPlainText(
  [for (var i = 0; i < 80; i++) 'Line $i of a long note'].join('\n'),
);

void main() {
  setUpAll(loadAppFonts);

  const sizes = <Size>[
    Size(320, 568),
    Size(360, 800),
    Size(412, 915),
    Size(915, 412),
    Size(768, 1024),
    Size(1280, 800),
  ];
  const scales = <double>[1, 2, 3];

  for (final size in sizes) {
    for (final scale in scales) {
      final label = '${size.width.toInt()}x${size.height.toInt()} scale $scale';

      testWidgets('editor and failed-save status fit at $label', (
        tester,
      ) async {
        final s = AppServices.inMemory();
        addTearDown(s.close);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        final live = s.notes.createNote(
          title: 'A title that is long enough to wrap onto a second line',
          body: jsonEncode(sample().toJson()),
        );
        await pumpEditor(tester, s, noteId: live.id, size: size);
        expect(tester.takeException(), isNull, reason: 'live note');
        final state = tester.state(find.byType(EditorScreen)) as dynamic;
        final session = state.session as EditorSession;
        session.status = SaveStatus.failed;
        // ignore: invalid_use_of_protected_member
        session.notifyListeners();
        await tester.pump();
        expect(find.text('Not saved yet, retrying…'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'failed status');
      });

      testWidgets('trash banner fits at $label', (tester) async {
        final s = AppServices.inMemory();
        addTearDown(s.close);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        final gone = s.notes.createNote(title: 'Gone', body: longBody());
        s.notes.trash([gone.id]);
        await pumpEditor(tester, s, noteId: gone.id, size: size);
        await tester.pumpAndSettle();
        expect(find.text('This note is in Trash'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'trash banner');
      });
    }
  }

  testWidgets('trash banner: one row when it fits, stacked when it does not', (
    tester,
  ) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final gone = s.notes.createNote(title: 'Gone', body: longBody());
    s.notes.trash([gone.id]);

    await pumpEditor(tester, s, noteId: gone.id, size: const Size(1280, 800));
    await tester.pumpAndSettle();
    final text = tester.getRect(find.text('This note is in Trash'));
    final restore = tester.getRect(find.text('Restore'));
    expect(restore.center.dy, closeTo(text.center.dy, 2));
    expect(restore.left, greaterThan(text.right));

    await setWindow(tester, const Size(320, 568));
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    await tester.pumpAndSettle();
    final big = tester.getRect(find.text('This note is in Trash'));
    final bigRestore = tester.getRect(find.text('Restore'));
    final forever = tester.getRect(find.text('Delete forever'));
    expect(bigRestore.top, greaterThanOrEqualTo(big.bottom));
    expect(forever.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  group('touch targets', () {
    Future<void> open(WidgetTester tester, TargetPlatform p, Size size) async {
      debugDefaultTargetPlatformOverride = p;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final s = AppServices.inMemory();
      addTearDown(s.close);
      final n = s.notes.createNote(title: 'Plan', body: longBody());
      await pumpEditor(tester, s, noteId: n.id, size: size);
    }

    testWidgets('Android: app bar and toolbar buttons are 48 dp', (
      tester,
    ) async {
      await open(tester, TargetPlatform.android, const Size(412, 915));
      for (final tip in ['Back', 'Copy note', 'Pin', 'More', 'Bold']) {
        final size = tester.getSize(find.byTooltip(tip).first);
        expect(size.shortestSide, greaterThanOrEqualTo(48), reason: tip);
      }
    });

    testWidgets('Linux: toolbar keeps its compact size', (tester) async {
      await open(tester, TargetPlatform.linux, const Size(1280, 800));
      expect(tester.getSize(find.byTooltip('Bold').first), const Size(36, 36));
    });
  });

  testWidgets('the bottom toolbar rides above the keyboard', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final s = AppServices.inMemory();
    addTearDown(s.close);
    final n = s.notes.createNote(title: 'Plan', body: longBody());
    const size = Size(360, 640);
    await pumpEditor(tester, s, noteId: n.id, size: size);
    final bar = find.byTooltip('Bold');
    expect(tester.getBottomLeft(bar).dy, lessThanOrEqualTo(size.height));

    // A 300 dp keyboard.
    tester.view.viewInsets = FakeViewPadding(
      bottom: 300 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(bar).dy, lessThanOrEqualTo(size.height - 300));
    expect(find.text('Plan'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The page still scrolls to the end of a long note above the toolbar.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -5000),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Line 79', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
