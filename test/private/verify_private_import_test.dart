import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/models.dart';

import '../fixtures/legacy_backup.dart';
import 'private_verify.dart';

/// The user's real backup, if one has been placed in `private/` (or named by
/// NOTES_PRIVATE_BACKUP). Output of this test is numbers and hashes only.
String? findPrivateBackup() {
  final env = Platform.environment['NOTES_PRIVATE_BACKUP'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  final dir = Directory('private');
  if (!dir.existsSync()) return null;
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .map((f) => f.path)
          .toList()
        ..sort();
  return files.isEmpty ? null : files.first;
}

void main() {
  final path = findPrivateBackup();

  test(
    'the real backup imports completely and stably (numbers only)',
    () {
      final result = verifyImport(File(path!).readAsStringSync());
      // ignore: avoid_print
      print('private import: ${jsonEncode(result.numbers())}');
      expect(result.failures, isEmpty);
      expect(result.sourceNotes, greaterThan(0));
    },
    skip: path == null
        ? 'no .json backup in private/ and NOTES_PRIVATE_BACKUP not set'
        : false,
  );

  group('verification helper (synthetic data)', () {
    test('passes on a faithful import of the realistic preset', () {
      final result = verifyImport(jsonEncode(realisticPreset()));
      expect(result.failures, isEmpty);
      expect(result.sourceNotes, 84);
      expect((result.active, result.archived, result.deleted), (42, 2, 40));
      expect(
        (result.landedActive, result.landedArchived, result.landedTrash),
        (42, 2, 40),
      );
      expect(result.reimportCreated, 0);
      expect(result.reimportUnchanged, 84);
      expect(result.reimportSeqDelta, 0);
      expect(result.idsHash, hasLength(64));
      expect(result.plainTextConverted, 3);
    });

    test('numbers() holds no text from the notes', () {
      final text = jsonEncode(realisticPreset());
      final out = jsonEncode(verifyImport(text).numbers());
      expect(out, isNot(contains('Title')));
      expect(out, isNot(contains('legacy-note')));
      expect(out, isNot(contains('Simple note')));
    });

    test('a changed body is caught and named by index only', () {
      final result = verifyImport(
        jsonEncode(realisticPreset()),
        tamper: (repo) {
          final n = repo.getNote('legacy-note-00005')!;
          repo.saveContent(
            n.id,
            title: n.title,
            body: '[{"insert":"SECRET TEXT\\n"}]',
            base: n.contentVv,
          );
        },
      );
      expect(result.failures, [
        'note #5: body differs',
        'note #5: updatedAt differs',
      ]);
      expect(result.failures.join(), isNot(contains('SECRET')));
      expect(result.failures.join(), isNot(contains('legacy-note')));
    });

    test('a missing note, a flag change and wrong counts are caught', () {
      final result = verifyImport(
        jsonEncode(realisticPreset()),
        tamper: (repo) {
          repo.purge(['legacy-note-00003']);
          repo.setPinned(['legacy-note-00004'], true); // 4 % 8 != 0
          repo.setArchived(['legacy-note-00006'], true);
        },
      );
      expect(result.ok, isFalse);
      expect(result.failures, contains('note #3: missing'));
      expect(result.failures.where((f) => f.startsWith('note #3')), isNotEmpty);
      expect(result.failures, contains('note #4: pinned differs'));
      expect(result.failures, contains('note #6: archived differs'));
      expect(result.failures, contains('active count differs'));
      for (final f in result.failures) {
        expect(
          f,
          matches(RegExp(r'^(note #\d+: [a-zA-Z ]+|\w+ count differs)$')),
        );
      }
    });

    test('compareNote: field by field', () {
      final row = <String, Object?>{
        'id': 'x',
        'title': 'T',
        'content': '[{"insert":"a\\n","attributes":{"bold":true}}]',
        'dateCreated': '2024-03-04T05:06:07.000',
        'dateModified': '2024-03-05T05:06:07.000',
        'isPinned': 1,
        'isArchived': false,
        'deletedAt': null,
      };
      final created = DateTime.parse('2024-03-04T05:06:07.000');
      final modified = DateTime.parse('2024-03-05T05:06:07.000');
      NoteRecord rec({
        String body = '[{"insert":"a\\n","attributes":{"bold":true}}]',
        String title = 'T',
        bool pinned = true,
        int? trashedAt,
        int? updatedAt,
      }) => NoteRecord.fromJson({
        'id': 'x',
        'title': title,
        'body': body,
        'createdAt': created.millisecondsSinceEpoch,
        'updatedAt': updatedAt ?? modified.millisecondsSinceEpoch,
        'contentHlc': '000000000000${'0000'}-legacy',
        'contentVv': {'legacy:1': 1},
        'purged': false,
        'pinned': pinned,
        'pinnedHlc': '0000000000000000-legacy',
        'archived': false,
        'archivedHlc': '0000000000000000-legacy',
        'folderId': null,
        'folderHlc': '0000000000000000-legacy',
        'trashedAt': trashedAt,
        'trashedHlc': '0000000000000000-legacy',
        'conflictOf': null,
        'conflictHlc': '0000000000000000-legacy',
      });
      expect(compareNote(row, rec()), isEmpty);
      expect(compareNote(row, rec(title: 'U')), ['title']);
      expect(compareNote(row, rec(pinned: false)), ['pinned']);
      expect(compareNote(row, rec(trashedAt: 5)), ['trashed']);
      expect(compareNote(row, rec(updatedAt: 1)), ['updatedAt']);
      expect(compareNote(row, rec(body: '[{"insert":"a\\n"}]')), ['body']);
      // Missing final newline: the importer appends one.
      final noNewline = {...row, 'content': '[{"insert":"a"}]'};
      expect(
        compareNote(noNewline, rec(body: '[{"insert":"a"},{"insert":"\\n"}]')),
        isEmpty,
      );
      // Plain text rule.
      final plain = {...row, 'content': 'just text'};
      expect(
        compareNote(plain, rec(body: '[{"insert":"just text\\n"}]')),
        isEmpty,
      );
    });
  });
}
