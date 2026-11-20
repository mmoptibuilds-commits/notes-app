import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/merge.dart';
import 'package:notes/sync/peers.dart';
import 'package:notes/sync/protocol.dart';
import 'package:notes/sync/secure_channel.dart';
import 'package:notes/sync/sync_session.dart';

import '../support/memory_transport.dart';

String body(String t) => jsonEncode([
  {'insert': '$t\n'},
]);

/// One simulated device.
class Device {
  Device._(this.db, this.repo, this.peers, this.identity, this.name);

  final AppDatabase db;
  final NoteRepository repo;
  final PeerStore peers;
  final DeviceIdentity identity;
  final String name;
  String get id => db.deviceId;

  static Future<Device> create(String name, {int skewMs = 0}) async {
    final db = AppDatabase.open(
      null,
      wallClock: () => DateTime.now().millisecondsSinceEpoch + skewMs,
    );
    final repo = NoteRepository(
      db,
      nowMs: () => DateTime.now().millisecondsSinceEpoch + skewMs,
    );
    return Device._(
      db,
      repo,
      PeerStore(db),
      await DeviceIdentity.fromPrivate(randomBytes(32)),
      name,
    );
  }

  void pairWith(Device other) => peers.add(
    id: other.id,
    name: other.name,
    publicKey: other.identity.publicKey,
  );

  /// Everything a device holds, comparable across devices.
  String dump() {
    final notes = [for (final (_, n) in repo.noteRecordsSince(0)) n.toJson()]
      ..sort((x, y) => '${x['id']}'.compareTo('${y['id']}'));
    final folders = [
      for (final (_, f) in repo.folderRecordsSince(0)) f.toJson(),
    ]..sort((x, y) => '${x['id']}'.compareTo('${y['id']}'));
    return jsonEncode({'notes': notes, 'folders': folders});
  }
}

/// Runs one sync between two devices. [a] dials. Returns both outcomes, or the
/// error each side ended with.
Future<(Object, Object)> syncPair(
  Device a,
  Device b, {
  void Function(MemoryEnd toB, MemoryEnd toA)? tamper,
  Duration idle = const Duration(seconds: 5),
}) async {
  final (ta, tb) = MemoryEnd.pair();
  tamper?.call(ta, tb);
  Future<Object> side(Future<SyncOutcome> Function() f) =>
      f().then<Object>((o) => o, onError: (Object e) => e);
  final chA = SecureChannel.initiateSession(
    ta,
    myId: a.id,
    identity: a.identity,
    peerId: b.id,
    peerPublicKey: b.identity.publicKey,
  );
  final chB = SecureChannel.respond(
    tb,
    myId: b.id,
    identity: b.identity,
    lookupPeer: b.peers.get,
    lookupOffer: (_) => null,
  );
  final results = await Future.wait([
    side(() async {
      final c = await chA;
      return SyncSession(
        channel: c,
        repo: a.repo,
        peers: a.peers,
        deviceName: a.name,
        idleTimeout: idle,
      ).run();
    }),
    side(() async {
      final c = await chB;
      return SyncSession(
        channel: c,
        repo: b.repo,
        peers: b.peers,
        deviceName: b.name,
        idleTimeout: idle,
      ).run();
    }),
  ]);
  return (results[0], results[1]);
}

SyncOutcome ok(Object o) {
  expect(o, isA<SyncOutcome>(), reason: '$o');
  return o as SyncOutcome;
}

void main() {
  late Device a;
  late Device b;
  setUp(() async {
    a = await Device.create('Laptop');
    b = await Device.create('Phone', skewMs: 2500);
    a.pairWith(b);
    b.pairWith(a);
  });
  tearDown(() {
    a.db.close();
    b.db.close();
  });

  test('two devices with different notes end up with the same notes, then a second sync is quiet', () async {
    a.repo.createNote(title: 'from laptop', body: body('hello'));
    final folder = a.repo.createFolder('Work');
    a.repo.createNote(title: 'filed', body: body('x'), folderId: folder.id);
    b.repo.createNote(title: 'from phone', body: body('world'));
    final (ra, rb) = await syncPair(a, b);
    final oa = ok(ra);
    final ob = ok(rb);
    expect(oa.sentRows, 3);
    expect(ob.sentRows, 1);
    expect(oa.created, 1);
    expect(ob.created, 3);
    expect(a.dump(), b.dump());
    expect(a.repo.listNotes().length, 3);
    expect(a.repo.listFolders().single.name, 'Work');
    // Second round: only the echo of what each just applied.
    final (r2a, r2b) = await syncPair(a, b);
    ok(r2a);
    ok(r2b);
    expect(a.dump(), b.dump());
    final (r3a, r3b) = await syncPair(a, b);
    expect(
      ok(r3a).sentRows + ok(r3b).sentRows,
      0,
      reason: 'nothing left to send once settled',
    );
    expect(a.peers.pendingFor(b.id), 0);
    expect(b.peers.pendingFor(a.id), 0);
  });

  test('edits, pins, trash and deletions travel in both directions', () async {
    final n1 = a.repo.createNote(title: 'edit me', body: body('v1'));
    final n2 = a.repo.createNote(title: 'bin me', body: body('x'));
    final n3 = a.repo.createNote(title: 'purge me', body: body('y'));
    await syncPair(a, b);
    b.repo.saveContent(
      n1.id,
      title: 'edit me',
      body: body('v2 from phone'),
      base: n1.contentVv,
    );
    b.repo.setPinned([n1.id], true);
    a.repo.trash([n2.id]);
    a.repo.purge([n3.id]);
    await syncPair(a, b);
    await syncPair(a, b);
    expect(a.dump(), b.dump());
    expect(a.repo.getNote(n1.id)!.preview, 'v2 from phone');
    expect(a.repo.getNote(n1.id)!.pinned, isTrue);
    expect(
      b.repo.getNote(n2.id)!.isTrashed,
      isTrue,
      reason: 'trash is kept, not deleted',
    );
    expect(b.repo.getNote(n3.id), isNull);
    expect(b.repo.getRecord(n3.id)!.purged, isTrue);
  });

  test('concurrent offline edits keep both versions on both devices', () async {
    final n = a.repo.createNote(title: 'Plan', body: body('base'));
    await syncPair(a, b);
    a.repo.saveContent(
      n.id,
      title: 'Plan',
      body: body('laptop edit'),
      base: n.contentVv,
    );
    b.repo.saveContent(
      n.id,
      title: 'Plan',
      body: body('phone edit'),
      base: n.contentVv,
    );
    await syncPair(a, b);
    await syncPair(a, b);
    expect(a.dump(), b.dump());
    for (final d in [a, b]) {
      expect(
        {for (final s in d.repo.listNotes()) s.preview},
        {'laptop edit', 'phone edit'},
      );
      expect(d.repo.counts().conflicts, 1);
    }
  });

  test('images follow the notes that use them, verified by hash', () async {
    final bytes = Uint8List.fromList(
      List.generate(500 * 1024, (i) => (i * 7) % 251),
    );
    final src = a.repo.putAttachment(bytes, 'image/png');
    final n = a.repo.createNote(
      body: jsonEncode([
        {
          'insert': {'image': src},
        },
        {'insert': '\n'},
      ]),
    );
    final (ra, rb) = await syncPair(a, b);
    expect(ok(ra).attachmentsSent, 1);
    expect(ok(rb).attachmentsReceived, 1);
    expect(b.repo.getAttachment(src), bytes);
    expect(b.repo.missingAttachments(), isEmpty);
    expect(b.repo.getNote(n.id), isNotNull);
  });

  test(
    'an image neither device has stays marked missing, not invented',
    () async {
      final ghost = 'att:${'e' * 64}';
      a.repo.createNote(
        body: jsonEncode([
          {
            'insert': {'image': ghost},
          },
          {'insert': '\n'},
        ]),
      );
      final (_, rb) = await syncPair(a, b);
      expect(ok(rb).attachmentsStillMissing, 1);
      expect(b.repo.missingAttachments(), ['e' * 64]);
    },
  );

  test(
    'a very large note and a large library cross in multiple pieces',
    () async {
      final huge = 'x' * (3 * 1024 * 1024);
      a.repo.createNote(
        title: 'huge',
        body: jsonEncode([
          {'insert': '$huge\n'},
        ]),
      );
      for (var i = 0; i < 600; i++) {
        a.repo.createNote(
          title: 'note $i',
          body: body('body of note number $i ' * 20),
        );
      }
      final (ra, rb) = await syncPair(a, b);
      expect(ok(ra).sentRows, 601);
      expect(ok(rb).created, 601);
      expect(a.dump(), b.dump());
      expect(b.repo.search('huge').length, 1);
    },
  );

  test('cursors advance only with a completed exchange', () async {
    a.repo.createNote(title: 'x', body: body('x'));
    expect(a.peers.get(b.id)!.sentCursor, 0);
    await syncPair(a, b);
    expect(
      a.peers.get(b.id)!.sentCursor,
      a.db.currentSeq == 0 ? 0 : greaterThan(0),
    );
    expect(b.peers.get(a.id)!.recvCursor, greaterThan(0));
    expect(a.peers.get(b.id)!.lastSyncAt, isNotNull);
  });

  group('interrupted connections', () {
    // Pull the cable after every possible number of frames sent by either
    // side. Whatever happens, no device may end up half-updated, and the next
    // clean sync must still bring both to the same state.
    for (final cutter in ['dialer', 'listener']) {
      test('cut after N frames by the $cutter', () async {
        final seedNotes = <String>[];
        for (var cut = 0; cut < 14; cut++) {
          final x = await Device.create('X');
          final y = await Device.create('Y');
          addTearDown(x.db.close);
          addTearDown(y.db.close);
          x.pairWith(y);
          y.pairWith(x);
          for (var i = 0; i < 5; i++) {
            x.repo.createNote(title: 'x$i', body: body('x $i'));
            y.repo.createNote(title: 'y$i', body: body('y $i'));
          }
          // A pair of concurrent edits makes the conflict copy atomicity matter.
          final shared = x.repo.createNote(
            id: 'shared-$cut',
            title: 'S',
            body: body('base'),
          );
          await syncPair(x, y);
          x.repo.saveContent(
            shared.id,
            title: 'S',
            body: body('X edit'),
            base: shared.contentVv,
          );
          y.repo.saveContent(
            shared.id,
            title: 'S',
            body: body('Y edit'),
            base: shared.contentVv,
          );
          final beforeX = x.dump();
          final beforeY = y.dump();
          final (r1, r2) = await syncPair(
            x,
            y,
            tamper: (ta, tb) =>
                (cutter == 'dialer' ? ta : tb).cutAfterSending = cut,
          );
          // Either side may have finished or failed; neither may be half-applied.
          for (final (dev, before, res, other) in [
            (x, beforeX, r1, y),
            (y, beforeY, r2, x),
          ]) {
            if (res is! SyncOutcome) {
              // A failed session leaves the device unchanged, or fully merged
              // with what the peer sent: never in between.
              final now = dev.dump();
              final merged = jsonDecode(now)['notes'] as List;
              final prior = jsonDecode(before)['notes'] as List;
              final onlyOld = now == before;
              final peerIds = {
                for (final n in jsonDecode(other.dump())['notes'] as List)
                  n['id'],
              };
              final newIds = {for (final n in merged) n['id']}
                  .difference({for (final n in prior) n['id']});
              // Everything new must have come from the peer, and the shared
              // note's conflict copy must exist whenever the merged note does.
              expect(
                newIds
                    .difference(peerIds)
                    .where((id) => !'$id'.contains('-'))
                    .length,
                lessThanOrEqualTo(1),
                reason: 'cut $cut',
              );
              if (!onlyOld) {
                final hasCopy = dev.repo.counts().conflicts == 1;
                final mergedNote = dev.repo.getRecord(shared.id)!;
                final merged2 = mergedNote.contentVv.counters.length > 1;
                if (merged2) {
                  expect(
                    hasCopy,
                    isTrue,
                    reason: 'cut $cut: merged note without its conflict copy',
                  );
                }
              }
            }
          }
          seedNotes.add(
            'cut $cut: ${r1 is SyncOutcome ? 'ok' : 'failed'}/${r2 is SyncOutcome ? 'ok' : 'failed'}',
          );
          // Recovery: clean syncs converge.
          for (var round = 0; round < 3; round++) {
            ok((await syncPair(x, y)).$1);
          }
          expect(x.dump(), y.dump(), reason: 'cut $cut did not recover');
          expect(
            {for (final s in x.repo.listNotes()) s.preview},
            containsAll(['X edit', 'Y edit']),
            reason: 'cut $cut lost an edit',
          );
        }
        expect(
          seedNotes.any((s) => s.contains('failed')),
          isTrue,
          reason: 'the cuts must actually interrupt something',
        );
      });
    }
  });

  group('a misbehaving peer', () {
    /// B is a raw channel script; A runs the real session against it.
    Future<Object> against(
      Future<void> Function(MessageStream ms) script, {
      Duration idle = const Duration(seconds: 2),
      Duration deadline = const Duration(minutes: 30),
    }) async {
      final (ta, tb) = MemoryEnd.pair();
      final chA = SecureChannel.initiateSession(
        ta,
        myId: a.id,
        identity: a.identity,
        peerId: b.id,
        peerPublicKey: b.identity.publicKey,
      );
      final chB = SecureChannel.respond(
        tb,
        myId: b.id,
        identity: b.identity,
        lookupPeer: b.peers.get,
        lookupOffer: (_) => null,
      );
      final scripted = chB.then((c) async {
        final ms = MessageStream(c);
        try {
          await script(ms);
        } on Object {
          // ignore: the peer's own failure is not under test
        } finally {
          await c.close();
        }
      });
      final res = await chA
          .then(
            (c) => SyncSession(
              channel: c,
              repo: a.repo,
              peers: a.peers,
              deviceName: 'A',
              idleTimeout: idle,
              sessionDeadline: deadline,
            ).run(),
          )
          .then<Object>((o) => o, onError: (Object e) => e);
      await scripted;
      return res;
    }

    Future<void> hello(MessageStream ms, {Object? from = 0}) async {
      await ms.send({
        't': 'hello',
        'proto': 1,
        'id': b.id,
        'name': 'B',
        'schema': 2,
        'from': from,
        'max': 0,
      });
      await ms.expect('hello');
    }

    test(
      'a row count that does not match is rejected and nothing is applied',
      () async {
        final r = await against((ms) async {
          await hello(ms);
          await ms.send({'t': 'rows', 'k': 'notes', 'rows': <Object>[]});
          await ms.send({'t': 'done', 'upTo': 5, 'count': 99});
        });
        expect(r, isA<SyncProtocolException>());
        expect(a.repo.listNotes(), isEmpty);
        expect(a.peers.get(b.id)!.recvCursor, 0);
      },
    );

    test('an unreadable row is skipped; the good rows still arrive', () async {
      final good = b.repo.createNote(title: 'good', body: body('fine'));
      final badJson = b.repo.getRecord(good.id)!.toJson()
        ..['id'] = 'bad-1'
        ..['body'] = 'this is not a delta';
      final r = await against((ms) async {
        await hello(ms);
        await ms.send({
          't': 'rows',
          'k': 'notes',
          'rows': [
            b.repo.getRecord(good.id)!.toJson(),
            badJson,
            {'garbage': true},
          ],
        });
        await ms.send({'t': 'done', 'upTo': 3, 'count': 3});
        await ms.expect('done'); // A's own rows
        await ms.expect('applied');
        await ms.send({'t': 'applied', 'upTo': 0});
        await ms.expect('need');
        await ms.send({'t': 'need', 'hashes': <Object>[]});
        await ms.send({'t': 'blobsdone'});
        await ms.expect('blobsdone');
        await ms.send({'t': 'bye'});
      });
      final o = ok(r);
      expect(o.created, 1);
      expect(o.invalidRows, 2);
      expect(
        a.peers.quarantined(),
        2,
        reason: 'unreadable rows are kept aside, not discarded',
      );
      expect(
        a.db
            .select('SELECT raw FROM quarantine')
            .map((r) => r['raw'] as String)
            .any((r) => r.contains('this is not a delta')),
        isTrue,
      );
      expect(a.repo.getNote(good.id), isNotNull);
      expect(a.repo.getRecord('bad-1'), isNull);
    });

    test(
      'a peer removed while a batch is paused cannot apply that batch',
      () async {
        final note = b.repo.createNote(
          id: 'removed-during-batch',
          title: 'must not arrive',
          body: body('paused batch'),
        );
        final result = await against((ms) async {
          await hello(ms);
          await ms.send({
            't': 'rows',
            'k': 'notes',
            'rows': [b.repo.getRecord(note.id)!.toJson()],
          });
          // Without `done`, the receiver cannot apply anything. Remove the
          // peer while the session is waiting for the rest of this batch.
          a.peers.remove(b.id);
          await ms.send({'t': 'done', 'upTo': 1, 'count': 1});
          await ms.expect('done');
          await ms.expect('applied');
          await ms.send({'t': 'applied', 'upTo': 0});
          await ms.expect('need');
          await ms.send({'t': 'need', 'hashes': <Object>[]});
          await ms.send({'t': 'blobsdone'});
          await ms.expect('blobsdone');
          await ms.send({'t': 'bye'});
        });

        expect(result, isA<SyncProtocolException>());
        expect(a.peers.get(b.id), isNull);
        expect(a.repo.getRecord(note.id), isNull);
        expect(a.peers.quarantined(), 0);
      },
    );

    test('unreadable rows are acknowledged while quarantine stays capped and raw is truncated', () async {
      const badCount = 501;
      final sourceIds = [
        for (var i = 0; i < badCount; i++) 'unreadable-$i',
        'over-limit',
      ];
      final rows = <Map<String, Object?>>[];
      for (var i = 0; i < badCount; i++) {
        final note = b.repo.createNote(
          id: sourceIds[i],
          title: 'source $i',
          body: body('valid source row $i'),
        );
        rows.add(
          b.repo.getRecord(note.id)!.toJson()..['body'] = 'not a delta $i',
        );
      }
      final largeSource = b.repo.createNote(
        id: 'over-limit',
        title: 'large source',
        body: body('valid large source row'),
      );
      rows.add(
        b.repo.getRecord(largeSource.id)!.toJson()..['body'] = 'x' * 2000001,
      );

      final result = await against((ms) async {
        await hello(ms);
        await ms.send({'t': 'rows', 'k': 'notes', 'rows': rows});
        await ms.send({'t': 'done', 'upTo': rows.length, 'count': rows.length});
        await ms.expect('done');
        final applied = await ms.expect('applied');
        expect(
          applied['upTo'],
          rows.length,
          reason: 'the entire batch, including invalid rows, is acknowledged',
        );
        await ms.send({'t': 'applied', 'upTo': 0});
        await ms.expect('need');
        await ms.send({'t': 'need', 'hashes': <Object>[]});
        await ms.send({'t': 'blobsdone'});
        await ms.expect('blobsdone');
        await ms.send({'t': 'bye'});
      });

      expect(ok(result).invalidRows, rows.length);
      expect(a.peers.get(b.id)!.recvCursor, rows.length);
      expect(a.peers.quarantined(), 500);
      final quarantined = a.db
          .select('SELECT raw FROM quarantine')
          .map((row) => row['raw'] as String)
          .toList();
      final quarantinedIds = <String>{};
      for (final raw in quarantined) {
        final match = RegExp(r'"id":"([^"]+)"').firstMatch(raw);
        if (match != null) quarantinedIds.add(match.group(1)!);
      }
      expect(quarantinedIds.length, 500);
      expect(quarantinedIds.contains('unreadable-0'), isFalse);
      expect(quarantinedIds.contains('unreadable-1'), isFalse);
      expect(quarantinedIds.contains('unreadable-2'), isTrue);
      expect(quarantinedIds.contains('unreadable-500'), isTrue);
      expect(quarantinedIds.contains('over-limit'), isTrue);
      final oversizedRaw = quarantined.singleWhere(
        (raw) => raw.contains('over-limit'),
      );
      expect(oversizedRaw.length, 2000000);
      expect(
        sourceIds.every((id) => b.repo.getRecord(id) != null),
        isTrue,
        reason: 'the sending device retains its authoritative source rows',
      );
    });

    test('a record claiming a clock far in the future aborts the session with nothing applied', () async {
      final n = b.repo.createNote(title: 'time traveller', body: body('x'));
      final j = b.repo.getRecord(n.id)!.toJson();
      final far = DateTime.now()
          .add(const Duration(days: 400))
          .millisecondsSinceEpoch
          .toRadixString(16)
          .padLeft(12, '0');
      j['contentHlc'] = '${far}0000-${b.id}';
      final r = await against((ms) async {
        await hello(ms);
        await ms.send({
          't': 'rows',
          'k': 'notes',
          'rows': [j],
        });
        await ms.send({'t': 'done', 'upTo': 1, 'count': 1});
        await ms.expect('done');
      });
      expect(r, isA<ClockSkewException>());
      expect(a.repo.listNotes(), isEmpty);
      expect(a.peers.get(b.id)!.recvCursor, 0);
    });

    test('unrequested image data is refused', () async {
      final r = await against((ms) async {
        await hello(ms);
        await ms.send({'t': 'done', 'upTo': 0, 'count': 0});
        await ms.expect('done');
        await ms.expect('applied');
        await ms.send({'t': 'applied', 'upTo': 0});
        await ms.expect('need');
        await ms.send({'t': 'need', 'hashes': <Object>[]});
        await ms.send({
          't': 'blob',
          'h': 'a' * 64,
          'mime': 'image/png',
          'size': 3,
          'i': 0,
          'n': 1,
          'd': base64Encode([1, 2, 3]),
        });
        await ms.expect('blobsdone');
      });
      expect(r, isA<SyncProtocolException>());
      expect(a.repo.missingAttachments(), isEmpty);
    });

    test('an image whose bytes do not match its hash is discarded', () async {
      final ghost = 'c' * 64;
      a.repo.createNote(
        body: jsonEncode([
          {
            'insert': {'image': 'att:$ghost'},
          },
          {'insert': '\n'},
        ]),
      );
      final r = await against((ms) async {
        await hello(ms);
        await ms.send({'t': 'done', 'upTo': 0, 'count': 0});
        await ms.expect('rows');
        await ms.expect('done');
        await ms.expect('applied');
        await ms.send({'t': 'applied', 'upTo': 0});
        await ms.expect('need');
        await ms.send({'t': 'need', 'hashes': <Object>[]});
        await ms.send({
          't': 'blob',
          'h': ghost,
          'mime': 'image/png',
          'size': 3,
          'i': 0,
          'n': 1,
          'd': base64Encode([9, 9, 9]),
        });
        await ms.send({'t': 'blobsdone'});
        await ms.expect('blobsdone');
        await ms.send({'t': 'bye'});
      });
      expect(ok(r).attachmentsReceived, 0);
      expect(a.repo.missingAttachments(), [ghost]);
    });

    test('a peer that goes silent times out cleanly', () async {
      final r = await against((ms) async {
        await hello(ms);
        await Future<void>.delayed(const Duration(seconds: 4));
      });
      expect(r, anyOf(isA<SyncTimeoutException>(), isA<TransportClosed>()));
    });

    test('a hello from a different device id is refused', () async {
      final r = await against((ms) async {
        await ms.send({
          't': 'hello',
          'proto': 1,
          'id': 'ffffffffffffffff',
          'name': 'B',
          'schema': 2,
          'from': 0,
          'max': 0,
        });
        await ms.receive();
      });
      expect(r, isA<SyncProtocolException>());
    });
  });

  test('a device restored from an older copy sends everything again instead of skipping changes', () async {
    for (var i = 0; i < 4; i++) {
      a.repo.createNote(title: 'a$i', body: body('a'));
    }
    await syncPair(a, b);
    await syncPair(a, b);
    // B believes it has received far more than A now has.
    b.db.transaction(() => b.peers.advance(a.id, received: 1000));
    a.repo.createNote(title: 'after restore', body: body('new'));
    await syncPair(a, b);
    expect(b.repo.listNotes().any((n) => n.title == 'after restore'), isTrue);
  });

  test('an unpaired device cannot sync', () async {
    final stranger = await Device.create('Stranger');
    addTearDown(stranger.db.close);
    stranger.peers.add(id: a.id, name: 'A', publicKey: a.identity.publicKey);
    final (rs, ra) = await syncPair(stranger, a);
    expect(rs, isNot(isA<SyncOutcome>()));
    expect(ra, isNot(isA<SyncOutcome>()));
    expect(a.repo.listNotes(), isEmpty);
    // Un-pairing locks a former peer out.
    a.peers.remove(b.id);
    final (r1, r2) = await syncPair(b, a);
    expect(r1, isNot(isA<SyncOutcome>()));
    expect(r2, isNot(isA<SyncOutcome>()));
  });

  test('describeSyncError gives plain sentences', () {
    expect(describeSyncError(TransportClosed()), contains('lost'));
    expect(
      describeSyncError(SyncProtocolException('x')),
      contains('unexpected'),
    );
    expect(shouldDial('0000000000000001', '0000000000000002'), isTrue);
    expect(shouldDial('0000000000000002', '0000000000000001'), isFalse);
  });

  test('after a peer is restored from an older copy, nothing it creates later is skipped', () async {
    for (var i = 0; i < 4; i++) {
      b.repo.createNote(id: 'old-$i', title: 'old $i', body: body('x'));
    }
    await syncPair(a, b);
    // A remembers having received far more than B has now (B was restored).
    a.db.transaction(() => a.peers.advance(b.id, received: 50));
    await syncPair(a, b);
    expect(
      a.peers.get(b.id)!.recvCursor,
      lessThan(50),
      reason: 'the cursor must follow the restored numbering',
    );
    // B goes on to write more notes than the stale cursor covered.
    for (var i = 0; i < 90; i++) {
      b.repo.createNote(id: 'new-$i', title: 'new $i', body: body('y'));
    }
    await syncPair(a, b);
    await syncPair(a, b);
    for (var i = 0; i < 90; i++) {
      expect(
        a.repo.getRecord('new-$i'),
        isNotNull,
        reason: 'note new-$i was skipped',
      );
    }
    expect(a.dump(), b.dump());
  });

  test('a repeated or unsolicited image reply is a protocol error', () async {
    final ghost = 'd' * 64;
    a.repo.createNote(
      body: jsonEncode([
        {
          'insert': {'image': 'att:$ghost'},
        },
        {'insert': '\n'},
      ]),
    );
    Future<Object> twice(String type) => (() async {
      final (ta, tb) = MemoryEnd.pair();
      final chA = SecureChannel.initiateSession(
        ta,
        myId: a.id,
        identity: a.identity,
        peerId: b.id,
        peerPublicKey: b.identity.publicKey,
      );
      final chB = SecureChannel.respond(
        tb,
        myId: b.id,
        identity: b.identity,
        lookupPeer: b.peers.get,
        lookupOffer: (_) => null,
      );
      final scripted = chB.then((c) async {
        final ms = MessageStream(c);
        try {
          await ms.send({
            't': 'hello',
            'proto': 1,
            'id': b.id,
            'name': 'B',
            'schema': 3,
            'from': 0,
            'max': 0,
          });
          await ms.expect('hello');
          await ms.send({'t': 'done', 'upTo': 0, 'count': 0});
          await ms.expect('rows');
          await ms.expect('done');
          await ms.expect('applied');
          await ms.send({'t': 'applied', 'upTo': 0});
          await ms.expect('need');
          await ms.send({'t': 'need', 'hashes': <Object>[]});
          await ms.send({'t': 'blobmissing', 'h': ghost});
          await ms.send({'t': type, 'h': ghost});
          await ms.expect('blobsdone');
        } on Object {
          // the peer's side is not under test
        } finally {
          await c.close();
        }
      });
      final res = await chA
          .then(
            (c) => SyncSession(
              channel: c,
              repo: a.repo,
              peers: a.peers,
              deviceName: 'A',
              idleTimeout: const Duration(seconds: 2),
            ).run(),
          )
          .then<Object>((o) => o, onError: (Object e) => e);
      await scripted;
      return res;
    })();
    expect(
      await twice('blobmissing'),
      isA<SyncProtocolException>(),
      reason: 'answering the same request twice',
    );
  });

  test(
    'a session that keeps looking busy still ends at its deadline',
    () async {
      final (ta, tb) = MemoryEnd.pair();
      final chA = SecureChannel.initiateSession(
        ta,
        myId: a.id,
        identity: a.identity,
        peerId: b.id,
        peerPublicKey: b.identity.publicKey,
      );
      final chB = SecureChannel.respond(
        tb,
        myId: b.id,
        identity: b.identity,
        lookupPeer: b.peers.get,
        lookupOffer: (_) => null,
      );
      var keepGoing = true;
      final scripted = chB.then((c) async {
        final ms = MessageStream(c);
        try {
          await ms.send({
            't': 'hello',
            'proto': 1,
            'id': b.id,
            'name': 'B',
            'schema': 3,
            'from': 0,
            'max': 0,
          });
          await ms.expect('hello');
          while (keepGoing) {
            // Empty batches forever: each message resets the idle timer.
            await ms.send({'t': 'rows', 'k': 'notes', 'rows': <Object>[]});
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        } on Object {
          // closed by the other side
        } finally {
          await c.close();
        }
      });
      final res = await chA
          .then(
            (c) => SyncSession(
              channel: c,
              repo: a.repo,
              peers: a.peers,
              deviceName: 'A',
              idleTimeout: const Duration(seconds: 5),
              sessionDeadline: const Duration(milliseconds: 600),
            ).run(),
          )
          .then<Object>((o) => o, onError: (Object e) => e);
      keepGoing = false;
      await scripted;
      expect(res, isA<SyncTimeoutException>());
    },
  );
}
