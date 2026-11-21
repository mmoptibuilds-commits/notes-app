import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/importer/notes_export.dart';
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
    await tester.tap(find.text('Import a backup or Notes export'));
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
    await tester.tap(find.text('Import a backup or Notes export'));
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
    await tester.tap(find.text('Import a backup or Notes export'));
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
    await tester.tap(find.text('Import a backup or Notes export'));
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

  testWidgets('Notes export restore requires confirmation and preserves data', (
    tester,
  ) async {
    const now =
        1700000000000; // must not be ahead of the real clock (skew guard)
    final source = AppServices.inMemory(clock: () => now);
    addTearDown(source.close);
    final original = source.notes.createNote(
      id: 'widget-restore-note',
      title: 'Restored note',
      body: bodyFromPlainText('synthetic export body'),
    );
    final text = exportAll(source.notes, now: DateTime.utc(2027, 1, 15));
    final s = AppServices.inMemory(clock: () => now);
    addTearDown(s.close);
    await pumpData(
      tester,
      s,
      DataScreen(
        pickBackup: () async =>
            XFile.fromData(utf8.encode(text), name: 'notes-export.json'),
      ),
    );

    await tester.tap(find.text('Import a backup or Notes export'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('1 notes: 1 new'), findsOneWidget);
    expect(s.notes.getRecord(original.id), isNull);

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Restore'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Restore finished'), findsOneWidget);
    expect(s.notes.getRecord(original.id)!.title, 'Restored note');
    expect(s.notes.getNote(original.id)!.body, original.body);
  });

  // file_selector has no save dialog on Android (getSaveLocation throws
  // UnimplementedError there); the export must go through the native picker.
  group('on Android the export uses the system save picker', () {
    const channel = MethodChannel('com.mmoptibuilds.notes/save');

    Future<AppServices> setUp(
      WidgetTester tester,
      Future<Object?> Function(MethodCall) handler,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final s = AppServices.inMemory(clock: () => 1700000000000);
      addTearDown(s.close);
      s.notes.createNote(
        id: 'android-export-note',
        title: 'Exported on Android',
        body: bodyFromPlainText('synthetic body'),
      );
      await pumpData(tester, s, const DataScreen());
      return s;
    }

    testWidgets('saves a parseable export and reports the file name', (
      tester,
    ) async {
      MethodCall? call;
      await setUp(tester, (c) async {
        call = c;
        return 'notes-export.json';
      });
      await tester.tap(find.text('Export all notes'));
      await tester.pumpAndSettle();

      expect(call!.method, 'saveFile');
      final args = call!.arguments as Map;
      expect(args['name'], matches(RegExp(r'^notes-export-.*\.json$')));
      expect(args['mime'], 'application/json');
      final parsed = parseExport(utf8.decode(args['bytes'] as Uint8List));
      expect(parsed.notes.single.id, 'android-export-note');
      expect(
        find.textContaining('Exported 1 notes to notes-export.json'),
        findsOneWidget,
      );
    });

    testWidgets('cancelling the picker says nothing and changes nothing', (
      tester,
    ) async {
      await setUp(tester, (c) async => null);
      await tester.tap(find.text('Export all notes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Exported'), findsNothing);
      expect(find.textContaining('failed'), findsNothing);
    });

    testWidgets('a picker failure is reported to the user', (tester) async {
      await setUp(tester, (c) async {
        throw PlatformException(code: 'write_failed', message: 'disk full');
      });
      await tester.tap(find.text('Export all notes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The export failed'), findsOneWidget);
      expect(find.textContaining('disk full'), findsOneWidget);
    });
  });

  testWidgets('Markdown files import as notes in one step', (tester) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    await pumpData(
      tester,
      s,
      DataScreen(
        pickMarkdown: () async => [
          XFile.fromData(
            Uint8List.fromList(utf8.encode('# Trip\n\n- [ ] Tickets\n')),
            name: 'trip.md',
          ),
          XFile.fromData(
            Uint8List.fromList(utf8.encode('plain words')),
            name: 'scratch.txt',
          ),
        ],
      ),
    );
    await tester.tap(find.text('Import Markdown files'));
    await tester.pumpAndSettle();
    expect(find.text('Imported 2 notes.'), findsOneWidget);
    expect(s.notes.counts().active, 2);
  });
}
