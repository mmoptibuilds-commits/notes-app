import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/hlc.dart';
import 'package:notes/core/version_vector.dart';
import 'package:notes/data/models.dart';
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
  });
}
