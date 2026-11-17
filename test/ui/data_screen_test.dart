import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/data/data_screen.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../fixtures/legacy_backup.dart';
import '../support/screenshot.dart';

Future<void> pumpData(
  WidgetTester tester,
  AppServices s,
  DataScreen screen,
) async {
  await setWindow(tester, const Size(412, 915));
  await tester.pumpWidget(
    AppScope(
      services: s,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(s.settings),
        home: screen,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('import shows a preview, imports on confirm, and can be undone', (
    tester,
  ) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    final backup = utf8.encode(encodeLegacyBackup(realisticPreset()));
    await pumpData(
      tester,
      s,
      DataScreen(
        pickBackup: () async =>
            XFile.fromData(backup, name: 'notebook-backup.json'),
      ),
    );
    await tester.tap(find.text('Import a Notebook backup'));
    await tester.pumpAndSettle();
    expect(find.text('Import this backup?'), findsOneWidget);
    expect(find.textContaining('84 notes'), findsOneWidget);
    await screenshot(tester, 'data_import_preview');
    // Preview alone changes nothing.
    expect(s.notes.counts().active + s.notes.counts().trash, 0);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Import'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Import finished'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final c = s.notes.counts();
    expect([c.active, c.archived, c.trash], [42, 2, 40]);
    expect(find.text('Past imports'), findsOneWidget);

    // Importing the same file again adds nothing.
    final seq = s.db.currentSeq;
    await tester.tap(find.text('Import a Notebook backup'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Import'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(s.db.currentSeq, seq);

    // Undo the first import (batches are listed newest first).
    await tester.tap(find.text('Undo').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo import'));
    await tester.pumpAndSettle();
    expect(find.text('Import undone'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final after = s.notes.counts();
    expect(after.active + after.archived + after.trash, 0);
  });

  testWidgets('a file that is not a backup is explained and nothing changes', (
    tester,
  ) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    await pumpData(
      tester,
      s,
      DataScreen(
        pickBackup: () async =>
            XFile.fromData(utf8.encode('{"hello": 1}'), name: 'x.json'),
      ),
    );
    await tester.tap(find.text('Import a Notebook backup'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(s.notes.counts().active, 0);
  });

  testWidgets('cancelling the preview imports nothing', (tester) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    final backup = utf8.encode(encodeLegacyBackup(realisticPreset()));
    await pumpData(
      tester,
      s,
      DataScreen(
        pickBackup: () async => XFile.fromData(backup, name: 'b.json'),
      ),
    );
    await tester.tap(find.text('Import a Notebook backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(s.notes.counts().active + s.notes.counts().trash, 0);
    expect(find.text('Past imports'), findsNothing);
  });

  testWidgets('export writes every note, including Trash', (tester) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    final a = s.notes.createNote(title: 'kept');
    final b = s.notes.createNote(title: 'binned');
    s.notes.trash([b.id]);
    final dir = Directory.systemTemp.createTempSync('notes export ui ');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = File('${dir.path}/out.json');
    await pumpData(tester, s, DataScreen(pickSaveFile: (_) async => out));
    await tester.runAsync(() async {
      await tester.tap(find.text('Export all notes'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    final json = jsonDecode(out.readAsStringSync()) as Map<String, Object?>;
    final ids = {for (final n in json['notes'] as List) (n as Map)['id']};
    expect(ids, {a.id, b.id});
  });
}
