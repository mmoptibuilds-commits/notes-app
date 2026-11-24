import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/hlc.dart';
import 'package:notes/core/version_vector.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/sync/merge.dart';
import 'package:notes/sync/three_way.dart';

String body(String text) => jsonEncode([
  {'insert': '$text\n'},
]);

NoteRecord record({
  required String title,
  required String text,
  required Map<String, int> vv,
  required Hlc hlc,
}) => NoteRecord(
  id: 'note-id',
  title: title,
  body: body(text),
  createdAt: 10,
  updatedAt: hlc.millis,
  contentHlc: hlc,
  contentVv: VersionVector(vv),
  purged: false,
  pinned: true,
  pinnedHlc: const Hlc(4, 0, 'a'),
  archived: false,
  archivedHlc: const Hlc(1, 0, 'a'),
  folderId: null,
  folderHlc: const Hlc(1, 0, 'a'),
  trashedAt: null,
  trashedHlc: const Hlc(1, 0, 'a'),
  conflictOf: null,
  conflictHlc: const Hlc(1, 0, 'a'),
);

void main() {
  group('mergeNotesThreeWay', () {
    final base = MergeBase(
      title: 'base title',
      body: body('first\nsecond'),
      contentVv: VersionVector({'base': 1}),
    );

    test('combines concurrent line changes into a fresh version', () {
      final local = record(
        title: 'local title',
        text: 'FIRST\nsecond',
        vv: {'base': 1, 'l': 1},
        hlc: const Hlc(20, 0, 'l'),
      );
      final remote = record(
        title: 'base title',
        text: 'first\nSECOND',
        vv: {'base': 1, 'r': 1},
        hlc: const Hlc(30, 0, 'r'),
      );
      final merged = mergeNotesThreeWay(
        local,
        remote,
        base: base,
        node: 'merge-node',
        now: const Hlc(40, 2, 'merge-node'),
      );
      expect(merged.conflictLoser, isNull);
      expect(digestBody(merged.merged.body).plainText, 'FIRST\nSECOND');
      expect(merged.merged.title, 'local title');
      expect(
        merged.merged.contentVv,
        VersionVector({'base': 1, 'l': 1, 'r': 1, 'merge-node': 1}),
      );
      expect(merged.merged.contentHlc, const Hlc(40, 2, 'merge-node'));
      expect(merged.merged.updatedAt, 40);
    });

    test('overlapping text, differing title edits and missing base fall back exactly', () {
      final local = record(
        title: 'left',
        text: 'LEFT\nsecond',
        vv: {'base': 1, 'l': 1},
        hlc: const Hlc(20, 0, 'l'),
      );
      final remote = record(
        title: 'right',
        text: 'RIGHT\nsecond',
        vv: {'base': 1, 'r': 1},
        hlc: const Hlc(30, 0, 'r'),
      );
      final now = const Hlc(40, 0, 'm');
      final expected = mergeNotes(local, remote);
      for (final result in [
        mergeNotesThreeWay(local, remote, base: base, node: 'm', now: now),
        mergeNotesThreeWay(local, remote, base: null, node: 'm', now: now),
      ]) {
        expect(
          jsonEncode(result.merged.toJson()),
          jsonEncode(expected.merged.toJson()),
        );
        expect(
          jsonEncode(result.conflictLoser?.toJson()),
          jsonEncode(expected.conflictLoser?.toJson()),
        );
      }
    });

    test('non-concurrent and purged inputs are exactly the ordinary merge', () {
      final local = record(
        title: 'l',
        text: 'one',
        vv: {'a': 2},
        hlc: const Hlc(2, 0, 'a'),
      );
      final remote = record(
        title: 'r',
        text: 'two',
        vv: {'a': 1},
        hlc: const Hlc(3, 0, 'b'),
      );
      final expected = mergeNotes(local, remote);
      final result = mergeNotesThreeWay(
        local,
        remote,
        base: base,
        node: 'm',
        now: const Hlc(4, 0, 'm'),
      );
      expect(
        jsonEncode(result.merged.toJson()),
        jsonEncode(expected.merged.toJson()),
      );
      expect(
        jsonEncode(result.conflictLoser?.toJson()),
        jsonEncode(expected.conflictLoser?.toJson()),
      );
    });

    test('a text merge keeps a trashed note trashed, also once stored', () {
      final local = record(
        title: 'base title',
        text: 'A\nb\nc',
        vv: {'base': 1, 'left': 1},
        hlc: const Hlc(20, 0, 'left'),
      ).copyWith(trashedAt: 500, trashedHlc: const Hlc(100, 0, 'trash'));
      final remote = record(
        title: 'base title',
        text: 'a\nB\nc',
        vv: {'base': 1, 'right': 1},
        hlc: const Hlc(30, 0, 'right'),
      );
      expect(mergeNotes(local, remote).merged.trashedAt, 500);
      final actual = mergeNotesThreeWay(
        local,
        remote,
        base: MergeBase(
          title: 'base title',
          body: body('a\nb\nc'),
          contentVv: VersionVector({'base': 1}),
        ),
        node: 'merge-node',
        now: const Hlc(900, 0, 'merge-node'),
      ).merged;
      expect(actual.trashedAt, 500);
      // The stored row must survive NoteRepository's own normalisation.
      final db = AppDatabase.open(null);
      addTearDown(db.close);
      final repo = NoteRepository(db);
      db.transaction(() => repo.writeRecord(actual));
      expect(repo.getRecord(actual.id)!.trashedAt, 500);
    });

    test('an edit newer than the trash still restores the note, as on LAN', () {
      final local = record(
        title: 'base title',
        text: 'A\nb\nc',
        vv: {'base': 1, 'left': 1},
        hlc: const Hlc(20, 0, 'left'),
      ).copyWith(trashedAt: 500, trashedHlc: const Hlc(10, 0, 'trash'));
      final remote = record(
        title: 'base title',
        text: 'a\nB\nc',
        vv: {'base': 1, 'right': 1},
        hlc: const Hlc(30, 0, 'right'),
      );
      expect(mergeNotes(local, remote).merged.trashedAt, isNull);
      final actual = mergeNotesThreeWay(
        local,
        remote,
        base: MergeBase(
          title: 'base title',
          body: body('a\nb\nc'),
          contentVv: VersionVector({'base': 1}),
        ),
        node: 'merge-node',
        now: const Hlc(900, 0, 'merge-node'),
      ).merged;
      expect(actual.trashedAt, isNull);
    });

    test('a base not dominated by both sides falls back exactly', () {
      final local = record(
        title: 'local',
        text: 'local',
        vv: {'local': 2},
        hlc: const Hlc(20, 0, 'local'),
      );
      final remote = record(
        title: 'remote',
        text: 'remote',
        vv: {'remote': 2},
        hlc: const Hlc(30, 0, 'remote'),
      );
      for (final invalidBase in [
        MergeBase(
          title: base.title,
          body: base.body,
          contentVv: VersionVector({'future': 1}),
        ),
      ]) {
        final actual = mergeNotesThreeWay(
          local,
          remote,
          base: invalidBase,
          node: 'm',
          now: const Hlc(40, 0, 'm'),
        );
        final expected = mergeNotes(local, remote);
        expect(
          jsonEncode(actual.merged.toJson()),
          jsonEncode(expected.merged.toJson()),
        );
        expect(
          jsonEncode(actual.conflictLoser?.toJson()),
          jsonEncode(expected.conflictLoser?.toJson()),
        );
      }
    });

    test('purged concurrent content falls back exactly', () {
      final live = record(
        title: 'live',
        text: 'live text',
        vv: {'base': 1, 'live': 1},
        hlc: const Hlc(20, 0, 'live'),
      );
      final purged = record(
        title: '',
        text: '',
        vv: {'base': 1, 'purged': 1},
        hlc: const Hlc(30, 0, 'purged'),
      ).copyWith(purged: true, body: emptyBodyJson);
      final expected = mergeNotes(live, purged);
      final actual = mergeNotesThreeWay(
        live,
        purged,
        base: base,
        node: 'm',
        now: const Hlc(40, 0, 'm'),
      );
      expect(
        jsonEncode(actual.merged.toJson()),
        jsonEncode(expected.merged.toJson()),
      );
      expect(
        jsonEncode(actual.conflictLoser?.toJson()),
        jsonEncode(expected.conflictLoser?.toJson()),
      );
    });
  });
}
