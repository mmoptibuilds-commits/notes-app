import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_screen.dart';
import 'package:notes/ui/library/desktop_sidebar.dart';
import 'package:notes/ui/library/note_card.dart';
import 'package:notes/ui/material.dart' show SizedBox, TextField;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Linux desktop creates and reopens encrypted notes', (
    tester,
  ) async {
    final dataDir = await Directory.systemTemp.createTemp(
      'notes-desktop-smoke-',
    );
    AppServices? services;

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } finally {
        services?.close();
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (dataDir.existsSync()) await dataDir.delete(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });

    services = await bootstrap(dataDir: dataDir.path);
    await tester.pumpWidget(NotesApp(services: services));
    await tester.pumpAndSettle();

    // A new database shows the first-run introduction. Skip it to reach the
    // desktop shell that this smoke test is intended to exercise.
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    Finder sidebar(String label) => find.descendant(
      of: find.byType(DesktopSidebar),
      matching: find.text(label),
    );
    Finder noteRow(String title) => find.descendant(
      of: find.byWidgetPredicate((w) => w is NoteCard || w is NoteRow),
      matching: find.text(title),
    );
    Finder titleField() => find.descendant(
      of: find.byType(EditorScreen),
      matching: find.byType(TextField),
    );
    QuillController quill() =>
        tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    EditorScreen editor() =>
        tester.widget<EditorScreen>(find.byType(EditorScreen));

    expect(find.byType(DesktopSidebar), findsOneWidget);
    expect(sidebar('New note'), findsOneWidget);
    expect(sidebar('All notes'), findsOneWidget);

    const firstTitle = 'Smoke note one';
    const firstBody = 'First note body survives restart.';
    const secondTitle = 'Smoke note two';
    const secondBody = 'Second note body survives restart.';

    await tester.tap(sidebar('New note'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(titleField(), findsOneWidget);
    await tester.enterText(titleField(), firstTitle);
    quill().replaceText(0, 0, firstBody, null);
    await tester.tap(find.byTooltip('Close note'));
    await tester.pumpAndSettle();

    expect(noteRow(firstTitle), findsOneWidget);
    expect(File('${dataDir.path}/notes.db').existsSync(), isTrue);
    final firstId = services.notes.listNotes().single.id;
    expect(services.notes.getNote(firstId)!.body, contains(firstBody));

    // Leave the second note open so selecting the first from the list flushes
    // it, then switch back and confirm the first editor content was retained.
    await tester.tap(sidebar('New note'));
    await tester.pumpAndSettle();
    await tester.enterText(titleField(), secondTitle);
    quill().replaceText(0, 0, secondBody, null);
    await tester.tap(noteRow(firstTitle));
    await tester.pumpAndSettle();

    expect(editor().noteId, firstId);
    expect(quill().document.toPlainText(), contains(firstBody));
    final storedSecond = services.notes.listNotes().singleWhere(
      (note) => note.title == secondTitle,
    );

    await tester.tap(noteRow(secondTitle));
    await tester.pumpAndSettle();
    expect(editor().noteId, storedSecond.id);
    expect(quill().document.toPlainText(), contains(secondBody));

    await tester.tap(noteRow(firstTitle));
    await tester.pumpAndSettle();
    expect(editor().noteId, firstId);
    expect(quill().document.toPlainText(), contains(firstBody));

    // Make Delete actionable on the library selection, then ensure focus in
    // Quill prevents it from trashing the selected note.
    await tester.longPress(noteRow(firstTitle));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byType(QuillEditor));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(services.notes.counts().active, 2);
    expect(services.notes.getNote(firstId)!.isTrashed, isFalse);
    expect(services.notes.getNote(firstId)!.body, contains(firstBody));

    await tester.tap(find.byTooltip('Close note'));
    await tester.pumpAndSettle();
    expect(services.notes.listNotes(), hasLength(2));

    // Remove the widget tree before closing its services, then reopen the same
    // encrypted database and key from the isolated directory.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    services.close();
    services = null;
    await Future<void>.delayed(const Duration(milliseconds: 25));

    services = await bootstrap(dataDir: dataDir.path);
    await tester.pumpWidget(NotesApp(services: services));
    await tester.pumpAndSettle();

    expect(find.byType(DesktopSidebar), findsOneWidget);
    expect(noteRow(firstTitle), findsOneWidget);
    expect(noteRow(secondTitle), findsOneWidget);
    expect(services.notes.listNotes(), hasLength(2));
    expect(services.notes.getNote(firstId)!.body, contains(firstBody));
    expect(services.notes.getNote(firstId)!.title, firstTitle);
    expect(services.notes.getNote(storedSecond.id)!.body, contains(secondBody));
    expect(services.notes.getNote(storedSecond.id)!.title, secondTitle);
  });
}
