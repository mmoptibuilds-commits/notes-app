import 'dart:convert';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/doc/checklist_projection.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../../support/screenshot.dart';

Delta sample() => Delta()
  ..insert('Weekend plan')
  ..insert('\n', {'header': 1})
  ..insert('Things to sort out before Monday, written in plain words.\n')
  ..insert('Buy oat milk')
  ..insert('\n', {'list': 'unchecked'})
  ..insert('Call the plumber')
  ..insert('\n', {'list': 'unchecked'})
  ..insert('Book train tickets', {'strike': true})
  ..insert('\n', {'list': 'checked'})
  ..insert('Renew library card')
  ..insert('\n', {'list': 'checked'})
  ..insert('print("hello")')
  ..insert('\n', {'code-block': true})
  ..insert('A quote worth keeping')
  ..insert('\n', {'blockquote': true})
  ..insert('Link text', {'link': 'https://example.org'})
  ..insert('\n');

Future<void> pumpEditor(
  WidgetTester tester,
  AppServices s, {
  String? noteId,
  Size size = const Size(412, 915),
}) async {
  await setWindow(tester, size);
  await tester.pumpWidget(
    AppScope(
      services: s,
      child: ListenableBuilder(
        listenable: s.settings,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(s.settings),
          home: EditorScreen(noteId: noteId),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets(
    'shows a note with its completed section collapsed, and reopening writes nothing',
    (tester) async {
      final s = AppServices.inMemory();
      addTearDown(s.close);
      final note = s.notes.createNote(body: jsonEncode(sample().toJson()));
      final seq = s.db.currentSeq;
      await pumpEditor(tester, s, noteId: note.id);
      expect(find.text('2 completed items'), findsOneWidget);
      expect(
        find.text('Book train tickets'),
        findsNothing,
        reason: 'collapsed',
      );
      await screenshot(tester, 'editor_phone_collapsed');
      await tester.tap(find.text('2 completed items'));
      await tester.pumpAndSettle();
      expect(find.text('Book train tickets'), findsOneWidget);
      await screenshot(tester, 'editor_phone_expanded');
      await tester.pumpWidget(const SizedBox());
      expect(s.db.currentSeq, seq);
    },
  );

  testWidgets(
    'ticking a checkbox moves it to the completed section; restoring brings it back',
    (tester) async {
      final s = AppServices.inMemory();
      addTearDown(s.close);
      final note = s.notes.createNote(body: jsonEncode(sample().toJson()));
      await pumpEditor(tester, s, noteId: note.id);
      expect(find.byType(QuillCheckboxPoint), findsNWidgets(2));
      await tester.tap(find.byType(QuillCheckboxPoint).first);
      await tester.pumpAndSettle();
      expect(find.byType(QuillCheckboxPoint), findsNWidgets(1));
      expect(find.text('3 completed items'), findsOneWidget);
      // Saved after the autosave delay, in place, never reordered.
      await tester.pump(const Duration(seconds: 2));
      final saved = deltaFromBody(s.notes.getNote(note.id)!.body);
      final text = saved.toList().map((o) => o.data).whereType<String>().join();
      expect(
        text.indexOf('Buy oat milk'),
        lessThan(text.indexOf('Call the plumber')),
      );
      expect(
        saved.toList().where((o) => o.attributes?['list'] == 'checked').length,
        3,
      );
      // Expand and restore one.
      await tester.tap(find.text('3 completed items'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Restore').first);
      await tester.pumpAndSettle();
      expect(find.text('2 completed items'), findsOneWidget);
      expect(find.byType(QuillCheckboxPoint), findsNWidgets(2));
      await tester.tap(find.byTooltip('Uncheck all'));
      await tester.pumpAndSettle();
      expect(find.textContaining('completed'), findsNothing);
      expect(find.byType(QuillCheckboxPoint), findsNWidgets(4));
      await tester.pumpWidget(const SizedBox());
      final after = deltaFromBody(s.notes.getNote(note.id)!.body);
      expect(
        after.toList().where((o) => o.attributes?['list'] == 'checked'),
        isEmpty,
      );
    },
  );

  testWidgets('deleting completed items offers undo', (tester) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    final note = s.notes.createNote(body: jsonEncode(sample().toJson()));
    await pumpEditor(tester, s, noteId: note.id);
    await tester.tap(find.byTooltip('Delete completed items'));
    await tester.pumpAndSettle();
    expect(find.textContaining('completed'), findsNothing);
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('2 completed items'), findsOneWidget);
  });

  testWidgets(
    'toolbar formats the selection, and follows the toolbar setting',
    (tester) async {
      final s = AppServices.inMemory();
      addTearDown(s.close);
      final note = s.notes.createNote(
        body: jsonEncode((Delta()..insert('hello world\n')).toJson()),
      );
      s.settings.toolbar = [ToolbarItem.bold, ToolbarItem.undo];
      await pumpEditor(tester, s, noteId: note.id);
      final quill = tester
          .widget<QuillEditor>(find.byType(QuillEditor))
          .controller;
      quill.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 5),
        ChangeSource.local,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Bold'));
      await tester.pump();
      expect(quill.document.toDelta().toList().first.attributes, {
        'bold': true,
      });
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(quill.document.toDelta().toList().first.attributes, isNull);
      s.settings.toolbar = [ToolbarItem.link, ToolbarItem.bold];
      await tester.pump();
      expect(find.byTooltip('Link'), findsOneWidget);
      expect(find.byTooltip('Italic'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a note in Trash is read-only with restore and delete-forever', (
    tester,
  ) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    final note = s.notes.createNote(
      title: 'Old',
      body: jsonEncode((Delta()..insert('gone\n')).toJson()),
    );
    s.notes.trash([note.id]);
    await pumpEditor(tester, s, noteId: note.id);
    expect(find.text('This note is in Trash'), findsOneWidget);
    expect(
      find.byTooltip('Bold'),
      findsNothing,
      reason: 'no toolbar while read-only',
    );
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('This note is in Trash'), findsNothing);
    expect(find.byTooltip('Bold'), findsOneWidget);
    expect(s.notes.getNote(note.id)!.isTrashed, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a new note appears in the library only after real content', (
    tester,
  ) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    await pumpEditor(tester, s);
    await tester.pump(const Duration(seconds: 2));
    expect(s.notes.counts().active, 0);
    final quill = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    quill.replaceText(
      0,
      0,
      'first thought',
      const TextSelection.collapsed(offset: 13),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(s.notes.listNotes().single.preview, 'first thought');
    await tester.pumpWidget(const SizedBox());
  });

  for (final (theme, name) in [
    (AppTheme.light, 'light'),
    (AppTheme.charcoal, 'charcoal'),
  ]) {
    testWidgets('desktop screenshot, $name', (tester) async {
      final s = AppServices.inMemory();
      addTearDown(s.close);
      s.settings.theme = theme;
      final note = s.notes.createNote(
        title: 'Weekend plan',
        body: jsonEncode(sample().toJson()),
      );
      await pumpEditor(tester, s, noteId: note.id, size: const Size(1280, 800));
      await screenshot(tester, 'editor_desktop_$name');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
