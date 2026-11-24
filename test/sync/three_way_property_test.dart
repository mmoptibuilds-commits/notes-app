import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/hlc.dart';
import 'package:notes/core/version_vector.dart';
import 'package:notes/data/models.dart';
import 'package:notes/sync/merge.dart';
import 'package:notes/sync/three_way.dart';

import 'three_way_test.dart' as fixtures;

String bodyFromRecord(NoteRecord r) => jsonEncode([r.title, r.body, r.purged]);

void main() {
  group('mergeNotesThreeWay properties', () {
    test('seeded three-device disjoint histories converge in every order', () {
      const seed = 0x73c91;
      final random = Random(seed);
      final common = fixtures.body('line0\nline1\nline2\nline3\nline4');
      final commonBase = MergeBase(
        title: 'base title',
        body: common,
        contentVv: VersionVector({'base': 1}),
      );
      final orders = <List<int>>[
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
      ];
      for (var iteration = 0; iteration < 120; iteration++) {
        final positions = <int>[];
        while (positions.length < 3) {
          final next = random.nextInt(5);
          if (!positions.contains(next)) positions.add(next);
        }
        final devices = List.generate(3, (device) {
          final lines = ['line0', 'line1', 'line2', 'line3', 'line4'];
          lines[positions[device]] = 'device$device-$iteration';
          return fixtures.record(
            title: 'base title',
            text: lines.join('\n'),
            vv: {'base': 1, 'device$device': 1},
            hlc: Hlc(100 + device, 0, 'device$device'),
          );
        });
        final results = <String>[];
        for (final order in orders) {
          var current = devices[order.first];
          var copies = 0;
          for (final index in order.skip(1)) {
            final merged = mergeNotesThreeWay(
              current,
              devices[index],
              base: commonBase,
              node: 'merge-node',
              now: const Hlc(500, 0, 'merge-node'),
            );
            if (merged.conflictLoser != null) copies++;
            current = merged.merged;
          }
          expect(
            copies,
            0,
            reason: 'seed=$seed iteration=$iteration order=$order',
          );
          results.add(bodyFromRecord(current));
        }
        expect(
          results.toSet().length,
          1,
          reason:
              'seed=$seed iteration=$iteration positions=$positions results=$results',
        );
      }
    });

    test(
      'seeded register merge matches mergeNotes and versions dominate both',
      () {
        const seed = 0x4e218;
        final random = Random(seed);
        final common = MergeBase(
          title: 'base title',
          body: fixtures.body('a\nb\nc'),
          contentVv: VersionVector({'base': 1}),
        );
        for (var iteration = 0; iteration < 250; iteration++) {
          final local = fixtures
              .record(
                title: random.nextBool() ? 'base title' : 'left title',
                text: 'A\nb\nc',
                vv: {'base': 1, 'left': iteration + 1},
                hlc: Hlc(100 + iteration * 2, 0, 'left'),
              )
              .copyWith(
                pinned: random.nextBool(),
                pinnedHlc: Hlc(10 + random.nextInt(1000), 0, 'pin-left'),
                archived: random.nextBool(),
                archivedHlc: Hlc(10 + random.nextInt(1000), 0, 'archive-left'),
                folderId: random.nextBool() ? 'folder-left' : null,
                folderHlc: Hlc(10 + random.nextInt(1000), 0, 'folder-left'),
                trashedAt: random.nextBool() ? 1000 + iteration : null,
                trashedHlc: Hlc(10 + random.nextInt(1000), 0, 'trash-left'),
                conflictOf: random.nextBool() ? 'conflict-left' : null,
                conflictHlc: Hlc(10 + random.nextInt(1000), 0, 'conflict-left'),
              );
          final remote = fixtures
              .record(
                title: random.nextBool() ? 'base title' : 'base title',
                text: 'a\nB\nc',
                vv: {'base': 1, 'right': iteration + 1},
                hlc: Hlc(101 + iteration * 2, 0, 'right'),
              )
              .copyWith(
                pinned: random.nextBool(),
                pinnedHlc: Hlc(10 + random.nextInt(1000), 0, 'pin-right'),
                archived: random.nextBool(),
                archivedHlc: Hlc(10 + random.nextInt(1000), 0, 'archive-right'),
                folderId: random.nextBool() ? 'folder-right' : null,
                folderHlc: Hlc(10 + random.nextInt(1000), 0, 'folder-right'),
                trashedAt: random.nextBool() ? 2000 + iteration : null,
                trashedHlc: Hlc(10 + random.nextInt(1000), 0, 'trash-right'),
                conflictOf: random.nextBool() ? 'conflict-right' : null,
                conflictHlc: Hlc(
                  10 + random.nextInt(1000),
                  0,
                  'conflict-right',
                ),
              );
          final expectedRegisters = mergeNotes(local, remote).merged;
          final result = mergeNotesThreeWay(
            local,
            remote,
            base: common,
            node: 'merge-node',
            now: const Hlc(9000, 3, 'merge-node'),
          );
          final actual = result.merged;
          final repro = 'seed=$seed iteration=$iteration';
          expect(actual.pinned, expectedRegisters.pinned, reason: repro);
          expect(actual.pinnedHlc, expectedRegisters.pinnedHlc, reason: repro);
          expect(actual.archived, expectedRegisters.archived, reason: repro);
          expect(
            actual.archivedHlc,
            expectedRegisters.archivedHlc,
            reason: repro,
          );
          expect(actual.folderId, expectedRegisters.folderId, reason: repro);
          expect(actual.folderHlc, expectedRegisters.folderHlc, reason: repro);
          expect(actual.trashedAt, expectedRegisters.trashedAt, reason: repro);
          // A note that stays trashed carries the merge clock (so storing it
          // cannot restore it); a restored note keeps the register stamp.
          expect(
            actual.trashedHlc,
            expectedRegisters.trashedAt == null
                ? expectedRegisters.trashedHlc
                : actual.contentHlc,
            reason: repro,
          );
          expect(
            actual.conflictOf,
            expectedRegisters.conflictOf,
            reason: repro,
          );
          expect(
            actual.conflictHlc,
            expectedRegisters.conflictHlc,
            reason: repro,
          );
          expect(
            actual.contentVv.compare(local.contentVv),
            VvOrder.dominates,
            reason: repro,
          );
          expect(
            actual.contentVv.compare(remote.contentVv),
            VvOrder.dominates,
            reason: repro,
          );
          if (result.conflictLoser == null) {
            expect(
              actual.contentHlc,
              const Hlc(9000, 3, 'merge-node'),
              reason: repro,
            );
          }
        }
      },
    );

    test('same concurrent pair merged independently has identical content', () {
      final pairBase = MergeBase(
        title: 'base title',
        body: fixtures.body('a\nb\nc'),
        contentVv: VersionVector({'base': 1}),
      );
      final left = fixtures.record(
        title: 'base title',
        text: 'LEFT\nb\nc',
        vv: {'base': 1, 'left': 1},
        hlc: const Hlc(20, 0, 'left'),
      );
      final right = fixtures.record(
        title: 'base title',
        text: 'a\nRIGHT\nc',
        vv: {'base': 1, 'right': 1},
        hlc: const Hlc(30, 0, 'right'),
      );
      final first = mergeNotesThreeWay(
        left,
        right,
        base: pairBase,
        node: 'merge-node',
        now: const Hlc(50, 0, 'merge-node'),
      );
      final second = mergeNotesThreeWay(
        right,
        left,
        base: pairBase,
        node: 'merge-node',
        now: const Hlc(50, 0, 'merge-node'),
      );
      expect(bodyFromRecord(first.merged), bodyFromRecord(second.merged));
      expect(first.conflictLoser, isNull);
      expect(second.conflictLoser, isNull);
    });
  });
}
