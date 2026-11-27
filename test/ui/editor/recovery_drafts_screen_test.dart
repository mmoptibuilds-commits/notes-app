import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/core/version_vector.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/data/editor_draft.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';

import '../../support/screenshot.dart';

void main() {
  setUpAll(loadAppFonts);

  for (final size in [
    const Size(412, 915),
    const Size(915, 412),
    const Size(1024, 700),
    const Size(1280, 800),
  ]) {
    for (final theme in AppTheme.values) {
      for (final layout in LibraryLayout.values) {
        testWidgets('recovery list fits $theme, $layout at $size', (
          tester,
        ) async {
          final isPhone = size.width < 900;
          debugDefaultTargetPlatformOverride = isPhone
              ? TargetPlatform.android
              : TargetPlatform.linux;
          final services = AppServices.inMemory();
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            services.close();
            await tester.binding.setSurfaceSize(null);
            debugDefaultTargetPlatformOverride = null;
          });
          services.settings.theme = theme;
          services.settings.layout = layout;
          services.settings.textScale = 1.4;
          services.notes.createNote(title: 'Existing note');
          services.notes.savePendingEditorDraft(
            PendingEditorDraft(
              id: 'layout-draft',
              noteId: null,
              folderId: null,
              title: 'Draft title',
              body: jsonEncode([
                {'insert': 'draft body\n'},
              ]),
              baseVv: VersionVector.empty.encode(),
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(NotesApp(services: services));
          await tester.pumpAndSettle();
          expect(find.byType(MaterialBanner), findsOneWidget);
          await tester.tap(find.text('Review drafts'));
          await tester.pumpAndSettle();

          expect(find.text('Recover drafts'), findsOneWidget);
          expect(find.text('Draft title'), findsOneWidget);
          final recover = find.widgetWithText(FilledButton, 'Recover draft');
          expect(recover, findsOneWidget);
          if (isPhone) {
            expect(tester.getSize(recover).height, greaterThanOrEqualTo(48));
          }
          if (layout == LibraryLayout.grid &&
              (size == const Size(412, 915) || size == const Size(1280, 800))) {
            await screenshot(
              tester,
              'recovery-${theme.name}-${size.width.toInt()}',
              path:
                  'build/screens/v132/recovery-${theme.name}-${size.width.toInt()}.png',
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('recovery controls have semantics and keyboard focus', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    final services = AppServices.inMemory();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      services.close();
      await tester.binding.setSurfaceSize(null);
      debugDefaultTargetPlatformOverride = null;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    services.notes.savePendingEditorDraft(
      PendingEditorDraft(
        id: 'focus-draft',
        noteId: null,
        folderId: null,
        title: 'Keyboard draft',
        body: jsonEncode([
          {'insert': 'focus body\n'},
        ]),
        baseVv: VersionVector.empty.encode(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await tester.pumpWidget(NotesApp(services: services));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review drafts'));
    await tester.pumpAndSettle();

    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('Recover drafts')).flagsCollection.isHeader,
      isTrue,
    );
    expect(find.bySemanticsLabel('Recover draft'), findsOneWidget);
    semantics.dispose();

    String focusedText() {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return '';
      return find
          .descendant(
            of: find.byElementPredicate((element) => element == context),
            matching: find.byType(Text),
          )
          .evaluate()
          .map((element) => (element.widget as Text).data ?? '')
          .join();
    }

    final focusedLabels = <String>[];
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      focusedLabels.add(focusedText());
    }
    expect(focusedLabels, contains('Discard'));
    expect(focusedLabels, contains('Recover draft'));
    final beforeShiftTab = FocusManager.instance.primaryFocus;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNot(same(beforeShiftTab)));
    expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, isTrue);
    await screenshot(
      tester,
      'recovery-keyboard-focus',
      path: 'build/screens/v132/recovery-keyboard-focus.png',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('library warns and a recovered draft becomes one saved note', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      services.close();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.binding.setSurfaceSize(const Size(412, 915));
    services.notes.savePendingEditorDraft(
      PendingEditorDraft(
        id: 'recovery-draft',
        noteId: null,
        folderId: null,
        title: 'Recovered title',
        body: jsonEncode([
          {'insert': 'recovered text\n'},
        ]),
        baseVv: VersionVector.empty.encode(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    await tester.pumpWidget(NotesApp(services: services));
    await tester.pumpAndSettle();
    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.textContaining('encrypted recovery draft'), findsOneWidget);

    await tester.tap(find.text('Review drafts'));
    await tester.pumpAndSettle();
    expect(find.text('Recover drafts'), findsOneWidget);
    expect(find.text('Recovered title'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('All notes'), findsOneWidget);
    await tester.tap(find.text('Review drafts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recover draft'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(services.notes.listNotes(), hasLength(1));
    expect(services.notes.listNotes().single.title, 'Recovered title');
    expect(services.notes.listNotes().single.preview, 'recovered text');
    expect(services.notes.pendingEditorDrafts(), isEmpty);
    expect(find.byType(MaterialBanner), findsNothing);
  });
}
