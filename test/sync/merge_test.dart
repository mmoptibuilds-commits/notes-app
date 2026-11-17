import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/hlc.dart';
import 'package:notes/core/version_vector.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/sync/merge.dart';

String body(String t) => jsonEncode([
  {'insert': '$t\n'},
]);

NoteRecord rec(
  String id, {
  String title = '',
  String text = '',
  Map<String, int> vv = const {'a': 1},
  Hlc? hlc,
  bool purged = false,
  bool pinned = false,
  Hlc? pinnedHlc,
  int? trashedAt,
  Hlc? trashedHlc,
  String? folderId,
  Hlc? folderHlc,
}) {
  final h = hlc ?? const Hlc(1000, 0, 'a');
  return NoteRecord(
    id: id,
    title: title,
    body: purged ? emptyBodyJson : body(text),
    createdAt: 1,
    updatedAt: h.millis,
    contentHlc: h,
    contentVv: VersionVector(vv),
    purged: purged,
    pinned: pinned,
    pinnedHlc: pinnedHlc ?? h,
    archived: false,
    archivedHlc: h,
    folderId: folderId,
    folderHlc: folderHlc ?? h,
    trashedAt: trashedAt,
    trashedHlc: trashedHlc ?? h,
    conflictOf: null,
    conflictHlc: h,
  );
}

String j(NoteRecord r) => jsonEncode(r.toJson());

void main() {
  group('mergeNotes', () {
    test('a version that includes the other wins; no conflict', () {
      final old = rec('n', text: 'old', vv: {'a': 1});
      final newer = rec(
        'n',
        text: 'new',
        vv: {'a': 2},
        hlc: const Hlc(2000, 0, 'a'),
      );
      for (final m in [mergeNotes(old, newer), mergeNotes(newer, old)]) {
        expect(m.merged.body, body('new'));
        expect(m.conflictLoser, isNull);
        expect(m.merged.contentVv, VersionVector({'a': 2}));
      }
    });

    test('independent edits: later clock wins, the other is kept, both orders agree', () {
      final a = rec(
        'n',
        text: 'from A',
        vv: {'a': 2},
        hlc: const Hlc(2000, 0, 'a'),
      );
      final b = rec(
        'n',
        text: 'from B',
        vv: {'a': 1, 'b': 1},
        hlc: const Hlc(3000, 0, 'b'),
      );
      final ab = mergeNotes(a, b);
      final ba = mergeNotes(b, a);
      expect(j(ab.merged), j(ba.merged));
      expect(ab.merged.body, body('from B'));
      expect(ab.conflictLoser!.body, body('from A'));
      expect(j(ba.conflictLoser!), j(ab.conflictLoser!));
      expect(ab.merged.contentVv, VersionVector({'a': 2, 'b': 1}));
    });

    test(
      'an edit beats an independent delete-forever, whatever the clocks say',
      () {
        final edit = rec(
          'n',
          text: 'keep me',
          vv: {'a': 2},
          hlc: const Hlc(2000, 0, 'a'),
        );
        final purge = rec(
          'n',
          purged: true,
          vv: {'a': 1, 'b': 1},
          hlc: const Hlc(9000, 0, 'b'),
        );
        for (final m in [mergeNotes(edit, purge), mergeNotes(purge, edit)]) {
          expect(m.merged.purged, isFalse);
          expect(m.merged.body, body('keep me'));
          expect(m.conflictLoser, isNull);
        }
      },
    );

    test('a delete-forever that includes the edit stays deleted', () {
      final edit = rec('n', text: 'x', vv: {'a': 1});
      final purge = rec(
        'n',
        purged: true,
        vv: {'a': 2},
        hlc: const Hlc(2000, 0, 'a'),
      );
      expect(mergeNotes(edit, purge).merged.purged, isTrue);
      expect(mergeNotes(purge, edit).merged.purged, isTrue);
    });

    test('two independent deletes stay deleted, with no copy', () {
      final x = rec(
        'n',
        purged: true,
        vv: {'a': 2},
        hlc: const Hlc(2000, 0, 'a'),
      );
      final y = rec(
        'n',
        purged: true,
        vv: {'a': 1, 'b': 1},
        hlc: const Hlc(3000, 0, 'b'),
      );
      final m = mergeNotes(x, y);
      expect(m.merged.purged, isTrue);
      expect(m.conflictLoser, isNull);
    });

    test('metadata merges per field: pinning on one device and editing on another both survive', () {
      final base = rec('n', text: 'base');
      final pinned = base.copyWith(
        pinned: true,
        pinnedHlc: const Hlc(2000, 0, 'a'),
      );
      final edited = base.copyWith(
        body: body('edited'),
        contentHlc: const Hlc(2500, 0, 'b'),
        contentVv: VersionVector({'a': 1, 'b': 1}),
      );
      final m = mergeNotes(pinned, edited);
      expect(m.merged.pinned, isTrue);
      expect(m.merged.body, body('edited'));
      expect(j(m.merged), j(mergeNotes(edited, pinned).merged));
      expect(m.conflictLoser, isNull);
    });

    test('the later trash/restore decision wins', () {
      final trashed = rec(
        'n',
        trashedAt: 5000,
        trashedHlc: const Hlc(2000, 0, 'a'),
      );
      final restored = rec(
        'n',
        trashedAt: null,
        trashedHlc: const Hlc(3000, 0, 'b'),
      );
      expect(mergeNotes(trashed, restored).merged.trashedAt, isNull);
      expect(mergeNotes(restored, trashed).merged.trashedAt, isNull);
      final laterTrash = rec(
        'n',
        trashedAt: 6000,
        trashedHlc: const Hlc(4000, 0, 'a'),
      );
      expect(mergeNotes(laterTrash, restored).merged.trashedAt, 6000);
    });

    test('editing after trashing on another device brings the note back', () {
      final base = rec('n', text: 'x', vv: {'a': 1});
      final trashed = base.copyWith(
        trashedAt: 5000,
        trashedHlc: const Hlc(2000, 0, 'a'),
      );
      final edited = base.copyWith(
        body: body('y'),
        contentHlc: const Hlc(3000, 0, 'b'),
        contentVv: VersionVector({'a': 1, 'b': 1}),
      );
      final m = mergeNotes(trashed, edited).merged;
      expect(m.trashedAt, isNull);
      expect(m.body, body('y'));
      expect(j(m), j(mergeNotes(edited, trashed).merged));
    });

    test(
      'the same version with different content keeps both, on both sides',
      () {
        final x = rec('n', text: 'one', vv: {'a': 1});
        final y = rec(
          'n',
          text: 'two',
          vv: {'a': 1},
          hlc: const Hlc(1000, 0, 'b'),
        );
        final xy = mergeNotes(x, y);
        final yx = mergeNotes(y, x);
        expect(j(xy.merged), j(yx.merged));
        expect(xy.conflictLoser, isNotNull);
        expect(
          {xy.merged.body, xy.conflictLoser!.body},
          {body('one'), body('two')},
        );
        expect(j(xy.conflictLoser!), j(yx.conflictLoser!));
      },
    );

    test('equal records merge to themselves', () {
      final x = rec('n', text: 'same');
      expect(j(mergeNotes(x, x).merged), j(x));
    });
  });

  group('RemoteApplier', () {
    late AppDatabase db;
    late NoteRepository repo;
    late RemoteApplier apply;
    var now = 10000;
    setUp(() {
      now = 10000;
      db = AppDatabase.open(null, wallClock: () => now);
      repo = NoteRepository(db, nowMs: () => now);
      apply = RemoteApplier(repo, nowMs: () => now);
    });
    tearDown(() => db.close());

    test('new notes arrive, duplicates change nothing and queue nothing', () {
      final r = rec(
        'n',
        text: 'hi',
        hlc: const Hlc(5000, 0, 'b'),
        vv: {'b': 1},
      );
      expect(apply.applyNote(r).kind, ApplyKind.created);
      final seq = db.currentSeq;
      expect(apply.applyNote(r).kind, ApplyKind.unchanged);
      expect(db.currentSeq, seq);
      expect(repo.getNote('n')!.preview, 'hi');
    });

    test(
      'a concurrent edit is merged and the other version is kept as a note',
      () {
        final mine = repo.createNote(id: 'n', title: 'T', body: body('mine'));
        final theirs = mine.contentVv.increment('phone');
        final remote = rec(
          'n',
          title: 'T',
          text: 'theirs',
          vv: theirs.counters,
          hlc: Hlc(now + 5, 0, 'phone'),
        );
        final r = apply.applyNote(
          remote.copyWith(contentVv: VersionVector({'phone': 1})),
        );
        expect(r.kind, ApplyKind.updated);
        expect(r.conflictCopyId, isNotNull);
        expect(repo.getNote('n')!.preview, 'theirs');
        expect(repo.getNote(r.conflictCopyId!)!.preview, 'mine');
        expect(repo.counts().conflicts, 1);
        // Receiving it again must not create another copy.
        apply.applyNote(
          remote.copyWith(contentVv: VersionVector({'phone': 1})),
        );
        expect(repo.counts().conflicts, 1);
      },
    );

    test(
      'applying advances the local clock past the peer so later edits win',
      () {
        final remote = rec(
          'n',
          text: 'x',
          hlc: Hlc(now + 3600000, 0, 'phone'),
          vv: {'phone': 1},
        );
        apply.applyNote(remote);
        expect(db.clock.now() > Hlc(now + 3600000, 0, 'phone'), isTrue);
      },
    );

    test('a peer whose clock is far in the future is refused and nothing is written', () {
      final far = rec(
        'n',
        text: 'x',
        hlc: Hlc(now + const Duration(days: 30).inMilliseconds, 0, 'bad'),
        vv: {'bad': 1},
      );
      final seq = db.currentSeq;
      expect(() => apply.applyNote(far), throwsA(isA<ClockSkewException>()));
      expect(db.currentSeq, seq);
      expect(repo.getRecord('n'), isNull);
    });

    test('tombstones travel: a deleted note stays deleted', () {
      final n = repo.createNote(id: 'n', body: body('x'));
      final purge = rec(
        'n',
        purged: true,
        vv: n.contentVv.increment('phone').counters,
        hlc: Hlc(now + 1, 0, 'phone'),
      );
      apply.applyNote(purge);
      expect(repo.getNote('n'), isNull);
      expect(repo.getRecord('n')!.purged, isTrue);
    });

    test('folders merge by field and delete wins only if later', () {
      final f = repo.createFolder('Work');
      final remoteRename = FolderRecord(
        id: f.id,
        name: 'Jobs',
        nameHlc: Hlc(now + 10, 0, 'phone'),
        deleted: false,
        deletedHlc: const Hlc(0, 0, ''),
        createdAt: 0,
      );
      apply.applyFolder(remoteRename);
      expect(repo.listFolders().single.name, 'Jobs');
      final remoteDelete = FolderRecord(
        id: f.id,
        name: 'Work',
        nameHlc: const Hlc(1, 0, 'x'),
        deleted: true,
        deletedHlc: Hlc(now + 20, 0, 'phone'),
        createdAt: 0,
      );
      apply.applyFolder(remoteDelete);
      expect(repo.listFolders(), isEmpty);
      expect(apply.applyFolder(remoteDelete).kind, ApplyKind.unchanged);
    });

    test('the same folder name created on two devices gets the same id', () {
      final other = AppDatabase.open(null);
      addTearDown(other.close);
      final a = repo.createFolder('Work');
      final b = NoteRepository(other).createFolder('work');
      expect(a.id, b.id);
      // A reused name after deletion does not collide with the old folder.
      repo.deleteFolder(a.id);
      expect(repo.createFolder('Work').id, isNot(a.id));
    });
  });

  group('convergence', () {
    // Several devices make random changes and exchange state at random, with
    // duplicated and reordered deliveries and skewed clocks. Once everything
    // has been exchanged, all devices must hold identical data.
    for (final seed in [1, 2, 3, 4, 5, 6, 7, 8]) {
      test('seed $seed', () {
        final rnd = Random(seed);
        var tick = 1000000;
        final skews = [0, 4000, -3000];
        final dbs = [
          for (var i = 0; i < 3; i++)
            AppDatabase.open(null, wallClock: () => tick + skews[i]),
        ];
        final repos = [
          for (var i = 0; i < 3; i++)
            NoteRepository(dbs[i], nowMs: () => tick + skews[i]),
        ];
        final appliers = [
          for (var i = 0; i < 3; i++)
            RemoteApplier(repos[i], nowMs: () => tick + skews[i]),
        ];
        addTearDown(() {
          for (final d in dbs) {
            d.close();
          }
        });
        final ids = <String>[];
        var counter = 0;

        void send(int from, int to) {
          final notes = repos[from].noteRecordsSince(0).toList()..shuffle(rnd);
          for (final (_, r) in notes) {
            if (rnd.nextInt(4) == 0) {
              continue; // dropped: a later sync fills it in
            }
            appliers[to].applyNote(r);
            if (rnd.nextInt(5) == 0) appliers[to].applyNote(r); // duplicate
          }
          for (final (_, f) in repos[from].folderRecordsSince(0)) {
            appliers[to].applyFolder(f);
          }
        }

        for (var step = 0; step < 220; step++) {
          tick += 1 + rnd.nextInt(50);
          final d = rnd.nextInt(3);
          final repo = repos[d];
          final live = [
            for (final id in ids)
              if (repo.getRecord(id) != null && !repo.getRecord(id)!.purged) id,
          ];
          switch (rnd.nextInt(14)) {
            case 0 || 1:
              final id = 'note-${counter++}';
              ids.add(id);
              repo.createNote(
                id: id,
                title: 't$counter',
                body: body('c$counter'),
              );
            case 2 || 3 || 4:
              if (live.isEmpty) break;
              final id = live[rnd.nextInt(live.length)];
              final n = repo.getRecord(id)!;
              repo.saveContent(
                id,
                title: n.title,
                body: body('e$step-$d'),
                base: n.contentVv,
              );
            case 5:
              if (live.isNotEmpty) {
                repo.setPinned([
                  live[rnd.nextInt(live.length)],
                ], rnd.nextBool());
              }
            case 6:
              if (live.isNotEmpty) {
                repo.setArchived([
                  live[rnd.nextInt(live.length)],
                ], rnd.nextBool());
              }
            case 7:
              if (live.isNotEmpty) {
                repo.trash([live[rnd.nextInt(live.length)]]);
              }
            case 8:
              if (live.isNotEmpty) {
                repo.restore([live[rnd.nextInt(live.length)]]);
              }
            case 9:
              if (live.isNotEmpty && rnd.nextInt(3) == 0) {
                repo.purge([live[rnd.nextInt(live.length)]]);
              }
            case 10:
              repo.createFolder(['Work', 'Home', 'Ideas'][rnd.nextInt(3)]);
            case 11:
              final folders = repo.listFolders();
              if (live.isNotEmpty) {
                repo.moveToFolder(
                  [live[rnd.nextInt(live.length)]],
                  folders.isEmpty || rnd.nextBool()
                      ? null
                      : folders[rnd.nextInt(folders.length)].id,
                );
              }
            default:
              final to = (d + 1 + rnd.nextInt(2)) % 3;
              send(d, to);
          }
        }
        // Final full exchange, repeated until quiet.
        for (var round = 0; round < 4; round++) {
          for (var a = 0; a < 3; a++) {
            for (var b = 0; b < 3; b++) {
              if (a != b) {
                for (final (_, r) in repos[a].noteRecordsSince(0)) {
                  appliers[b].applyNote(r);
                }
                for (final (_, f) in repos[a].folderRecordsSince(0)) {
                  appliers[b].applyFolder(f);
                }
              }
            }
          }
        }
        String dump(NoteRepository r) {
          final notes = [for (final (_, n) in r.noteRecordsSince(0)) n.toJson()]
            ..sort((x, y) => '${x['id']}'.compareTo('${y['id']}'));
          final folders = [
            for (final (_, f) in r.folderRecordsSince(0)) f.toJson(),
          ]..sort((x, y) => '${x['id']}'.compareTo('${y['id']}'));
          return jsonEncode({'notes': notes, 'folders': folders});
        }

        final first = dump(repos[0]);
        expect(dump(repos[1]), first, reason: 'device 1 differs from device 0');
        expect(dump(repos[2]), first, reason: 'device 2 differs from device 0');
        expect(jsonDecode(first)['notes'], isNotEmpty);
      });
    }
  });

  test('no edit is silently lost: both sides of a concurrent edit exist afterwards', () {
    final a = AppDatabase.open(null);
    final b = AppDatabase.open(null);
    addTearDown(() {
      a.close();
      b.close();
    });
    final ra = NoteRepository(a);
    final rb = NoteRepository(b);
    final applyA = RemoteApplier(ra);
    final applyB = RemoteApplier(rb);
    // One sync direction: everything the sender changed, in change order,
    // applied as one atomic batch (the conflict copy precedes the note that
    // resolved it, and neither can arrive without the other).
    void pull(NoteRepository from, RemoteApplier into) =>
        into.repo.db.transaction(() {
          for (final (_, f) in from.folderRecordsSince(0)) {
            into.applyFolder(f);
          }
          for (final (_, r) in from.noteRecordsSince(0)) {
            into.applyNote(r);
          }
        });

    final n = ra.createNote(id: 'shared', title: 'Plan', body: body('base'));
    pull(ra, applyB);
    // Both go offline and edit.
    ra.saveContent(
      'shared',
      title: 'Plan',
      body: body('laptop edit'),
      base: n.contentVv,
    );
    rb.saveContent(
      'shared',
      title: 'Plan',
      body: body('phone edit'),
      base: n.contentVv,
    );
    // They meet.
    pull(ra, applyB);
    pull(rb, applyA);
    pull(ra, applyB);
    for (final repo in [ra, rb]) {
      final texts = {for (final s in repo.listNotes()) s.preview};
      expect(texts, {
        'laptop edit',
        'phone edit',
      }, reason: 'each device keeps both versions');
      expect(repo.counts().conflicts, 1);
    }
  });
}
