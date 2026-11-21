import 'dart:convert';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../../support/screenshot.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('checking an earlier item keeps the caret on the same text', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    final note = services.notes.createNote(
      body: jsonEncode(
        (Delta()
              ..insert('checked before caret')
              ..insert('\n', {'list': 'unchecked'})
              ..insert('target character stays here\n'))
            .toJson(),
      ),
    );

    await setWindow(tester, const Size(412, 915));
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: ListenableBuilder(
          listenable: services.settings,
          builder: (context, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(services.settings),
            home: EditorScreen(noteId: note.id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final quill = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    final before = quill.document.toPlainText();
    final targetStart = before.indexOf('target');
    const offsetInTarget = 4;
    quill.updateSelection(
      TextSelection.collapsed(offset: targetStart + offsetInTarget),
      ChangeSource.local,
    );
    await tester.pump();

    await tester.tap(find.byType(QuillCheckboxPoint).first);
    await tester.pumpAndSettle();

    final after = quill.document.toPlainText();
    expect(after, contains('target character stays here'));
    expect(quill.selection.extentOffset, offsetInTarget);
    expect(after[quill.selection.extentOffset], 'e');
  });

  testWidgets('submitting the title preserves the existing body caret', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    final note = services.notes.createNote(
      title: 'A title',
      body: jsonEncode(
        (Delta()..insert('body character stays here\n')).toJson(),
      ),
    );

    await setWindow(tester, const Size(412, 915));
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: ListenableBuilder(
          listenable: services.settings,
          builder: (context, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(services.settings),
            home: EditorScreen(noteId: note.id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final quill = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    const bodyCaret = 12;
    quill.updateSelection(
      const TextSelection.collapsed(offset: bodyCaret),
      ChangeSource.local,
    );
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(EditorScreen),
        matching: find.byType(TextField),
      ),
    );
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(quill.selection, const TextSelection.collapsed(offset: bodyCaret));
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<QuillRawEditorState>(),
      isNotNull,
    );
  });
}
