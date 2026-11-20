import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/importer/notes_export.dart';
import 'package:notes/importer/notes_restore.dart';
import 'package:notes/sync/merge.dart';

void main() {
  final databases = <AppDatabase>[];
  late AppDatabase db;
  late NoteRepository repo;
  late int now;

  AppDatabase openDatabase() {
    final opened = AppDatabase.open(null, wallClock: () => now);
    databases.add(opened);
    return opened;
  }

  NoteRepository repository(AppDatabase database) =>
      NoteRepository(database, nowMs: () => now);

  setUp(() {
    now = 1800000000000;
    databases.clear();
    db = openDatabase();
    repo = repository(db);
  });
  tearDown(() {
    for (final opened in databases) {
      opened.close();
    }
  });

  test('round trips notes, metadata, folders, attachments and tombstones', () {
    final folder = repo.createFolder('Work');
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final source = repo.putAttachment(bytes, 'image/png');
    final body = jsonEncode([
      {'insert': 'kept body\n'},
      {
        'insert': {'image': source},
      },
      {'insert': '\n'},
    ]);
    final pinned = repo.createNote(
      id: 'round-trip-note',
      title: 'A note',
      body: body,
      folderId: folder.id,
    );
    repo.setPinned([pinned.id], true);
    repo.setArchived([pinned.id], true);
    final trashed = repo.createNote(title: 'In Trash');
    repo.trash([trashed.id]);
    final deletedForever = repo.createNote(title: 'Delete forever');
    repo.purge([deletedForever.id]);

    final text = exportAll(repo, now: DateTime.utc(2027, 1, 15));
    final targetDb = openDatabase();
    final target = repository(targetDb);
    final restorer = NotesExportRestorer(target, nowMs: () => now);
    final preview = restorer.inspect(text);
    expect(preview.format, exportFormat);
    expect(preview.version, exportVersion);
    expect(preview.noteCount, 3);
    expect(preview.folderCount, 1);
    expect(preview.attachmentCount, 1);
    expect(preview.newNotes, 3);
    expect(preview.identicalNotes, 0);
    expect(preview.newFolders, 1);
    expect(preview.newAttachments, 1);
    expect(target.counts().active + target.counts().archived, 0);

    final report = restorer.apply(text);
    expect(report.notesCreated, 3);
    expect(report.foldersCreated, 1);
    expect(report.attachmentsAdded, 1);
    expect(
      target.getRecord(pinned.id)!.toJson(),
      repo.getRecord(pinned.id)!.toJson(),
    );
    expect(target.getNote(pinned.id)!.body, body);
    expect(target.getNote(pinned.id)!.title, 'A note');
    expect(target.getRecord(pinned.id)!.pinned, isTrue);
    expect(target.getRecord(pinned.id)!.archived, isTrue);
    expect(target.getRecord(trashed.id)!.trashedAt, isNotNull);
    expect(target.getRecord(deletedForever.id)!.purged, isTrue);
    expect(
      target.getFolderRecord(folder.id)!.toJson(),
      repo.getFolderRecord(folder.id)!.toJson(),
    );
    expect(target.getAttachment(sha256Hex(bytes)), bytes);
    expect(
      (target.db.select('SELECT mime, size FROM attachments').single).values,
      ['image/png', bytes.length],
    );
  });

  test(
    'keeps a newer overlapping edit and never resurrects a newer tombstone',
    () {
      final original = repo.createNote(
        id: 'overlap-note',
        title: 'From export',
        body: bodyFromPlainText('export body'),
      );
      final text = exportAll(repo, now: DateTime.utc(2027, 1, 15));
      final targetDb = openDatabase();
      final target = repository(targetDb);
      final restorer = NotesExportRestorer(target, nowMs: () => now);
      restorer.apply(text);

      final local = target.getNote(original.id)!;
      target.saveContent(
        original.id,
        title: 'Edited here',
        body: bodyFromPlainText('local newer body'),
        base: local.contentVv,
      );
      final preview = restorer.inspect(text);
      expect(preview.conflictingNotes, 1);
      expect(preview.potentialConflictCopies, 0);
      final beforeRepeat = targetDb.currentSeq;
      final repeat = restorer.apply(text);
      expect(repeat.notesUnchanged, 1);
      expect(repeat.conflictCopies, 0);
      expect(targetDb.currentSeq, beforeRepeat);
      expect(target.getNote(original.id)!.title, 'Edited here');
      expect(
        target.getNote(original.id)!.body,
        bodyFromPlainText('local newer body'),
      );

      target.purge([original.id]);
      final purgeSeq = targetDb.currentSeq;
      restorer.apply(text);
      expect(target.getRecord(original.id)!.purged, isTrue);
      expect(target.getNote(original.id), isNull);
      expect(targetDb.currentSeq, purgeSeq);
    },
  );

  test('keeps a conflict copy for concurrent content edits', () {
    final base = repo.createNote(
      id: 'concurrent-note',
      title: 'Base',
      body: bodyFromPlainText('base'),
    );
    final baseExport = exportAll(repo, now: DateTime.utc(2027, 1, 15));
    final targetDb = openDatabase();
    final target = repository(targetDb);
    final restorer = NotesExportRestorer(target, nowMs: () => now);
    restorer.apply(baseExport);

    final sourceBase = repo.getNote(base.id)!;
    repo.saveContent(
      base.id,
      title: 'Source edit',
      body: bodyFromPlainText('source body'),
      base: sourceBase.contentVv,
    );
    final targetBase = target.getNote(base.id)!;
    target.saveContent(
      base.id,
      title: 'Local edit',
      body: bodyFromPlainText('local body'),
      base: targetBase.contentVv,
    );
    final concurrentExport = exportAll(repo, now: DateTime.utc(2027, 1, 16));
    final incoming = parseExport(concurrentExport).notes.single;
    final local = target.getRecord(base.id)!;
    final expected = mergeNotes(local, incoming);
    expect(expected.conflictLoser, isNotNull);
    expect(restorer.inspect(concurrentExport).potentialConflictCopies, 1);

    final report = restorer.apply(concurrentExport);
    expect(report.conflictCopies, 1);
    final merged = target.getRecord(base.id)!;
    expect(merged.body, expected.merged.body);
    final copy = target.getRecord(
      NoteRepository.conflictCopyOf(expected.conflictLoser!).id,
    )!;
    expect(copy.body, expected.conflictLoser!.body);
    expect(copy.conflictOf, base.id);

    final seq = targetDb.currentSeq;
    final repeated = restorer.apply(concurrentExport);
    expect(repeated.notesUnchanged, 1);
    expect(repeated.conflictCopies, 0);
    expect(targetDb.currentSeq, seq);
  });

  test('a failure after a prior note write rolls the whole restore back', () {
    repo.createFolder('Rollback folder');
    repo.createNote(title: 'First');
    repo.createNote(title: 'Second');
    final text = exportAll(repo, now: DateTime.utc(2027, 1, 15));
    final targetDb = openDatabase();
    final target = repository(targetDb);
    final before = _dumpDatabase(targetDb);

    expect(
      () => NotesExportRestorer(target, nowMs: () => now).apply(
        text,
        onRecord: (index) {
          if (index == 1) throw StateError('injected restore failure');
        },
      ),
      throwsStateError,
    );
    expect(_dumpDatabase(targetDb), before);
  });

  group('rejects malformed exports without writes', () {
    late String valid;
    late Uint8List sourceBytes;
    late AppDatabase targetDb;
    late NotesExportRestorer restorer;

    setUp(() {
      repo.createNote(title: 'Source');
      sourceBytes = Uint8List.fromList([7, 8, 9]);
      repo.putAttachment(sourceBytes, 'image/png');
      valid = exportAll(repo, now: DateTime.utc(2027, 1, 15));
      targetDb = openDatabase();
      restorer = NotesExportRestorer(repository(targetDb), nowMs: () => now);
    });

    void rejects(String text, Matcher matcher) {
      final before = _dumpDatabase(targetDb);
      expect(() => restorer.inspect(text), throwsA(matcher));
      expect(() => restorer.apply(text), throwsA(matcher));
      expect(_dumpDatabase(targetDb), before);
    }

    test('damaged JSON', () => rejects('{"format":', isA<FormatException>()));

    test('unknown Notes export format name is rejected', () {
      final json = _exportMap(valid)..['format'] = 'other';
      rejects(
        jsonEncode(json),
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Notes export format'),
        ),
      );
    });

    test('newer version', () {
      final json = _exportMap(valid)..['version'] = exportVersion + 1;
      rejects(
        jsonEncode(json),
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('supports version'),
        ),
      );
    });

    test('truncated attachment data', () {
      final json = _exportMap(valid);
      final attachments = json['attachments'] as List;
      (attachments.single as Map)['data'] = 'AA=';
      rejects(jsonEncode(json), isA<FormatException>());
    });

    test('attachment size mismatch', () {
      final json = _exportMap(valid);
      final attachments = json['attachments'] as List;
      (attachments.single as Map)['size'] = sourceBytes.length + 1;
      rejects(jsonEncode(json), isA<FormatException>());
    });

    test('attachment hash mismatch', () {
      final json = _exportMap(valid);
      final attachments = json['attachments'] as List;
      (attachments.single as Map)['hash'] = 'a' * 64;
      rejects(jsonEncode(json), isA<FormatException>());
    });

    test('duplicate note ids', () {
      final json = _exportMap(valid);
      final notes = json['notes'] as List;
      notes.add(notes.single);
      rejects(jsonEncode(json), isA<FormatException>());
    });

    test('legacy backup is identified as the other format', () {
      rejects(
        jsonEncode({'version': 11, 'notes': []}),
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Notebook backup'),
        ),
      );
    });
  });
}

Map<String, Object?> _exportMap(String text) =>
    (jsonDecode(text) as Map).cast<String, Object?>();

String _dumpDatabase(AppDatabase db) {
  final output = StringBuffer('seq=${db.currentSeq}\n');
  for (final table in [
    'notes',
    'folders',
    'attachments',
    'note_attachments',
    'local_meta',
  ]) {
    output.writeln('## $table');
    for (final row in db.select('SELECT * FROM $table ORDER BY 1, 2')) {
      output.writeln(
        row.values
            .map((value) => value is Uint8List ? base64Encode(value) : value)
            .join('|'),
      );
    }
  }
  return output.toString();
}
