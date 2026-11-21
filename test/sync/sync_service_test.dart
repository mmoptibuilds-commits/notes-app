import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/pairing.dart';
import 'package:notes/sync/peers.dart';
import 'package:notes/sync/protocol.dart';
import 'package:notes/sync/secure_channel.dart';
import 'package:notes/sync/sync_service.dart';
import 'package:notes/sync/sync_session.dart';
import 'package:notes/sync/tcp_transport.dart';

String body(String t) => jsonEncode([
  {'insert': '$t\n'},
]);

/// The device that accepted a session finishes its own bookkeeping (cursor,
/// busy flag) just after the dialing side returns; wait until both are idle.
Future<void> _quiet(Node x, Node y) async {
  for (var i = 0; i < 300 && (x.service.syncing || y.service.syncing); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class Node {
  Node._(this.db, this.repo, this.peers, this.service, this.name);
  final AppDatabase db;
  final NoteRepository repo;
  final PeerStore peers;
  final SyncService service;
  final String name;
  String get id => db.deviceId;

  static Future<Node> start(String name, {Duration? handshakeTimeout}) async {
    final db = AppDatabase.open(null);
    final repo = NoteRepository(db);
    final peers = PeerStore(db);
    final identity = await DeviceIdentity.loadOrCreate(db);
    final service = SyncService(
      repo: repo,
      peers: peers,
      identity: identity,
      deviceName: name,
      port: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
      handshakeTimeout: handshakeTimeout ?? const Duration(seconds: 6),
      localAddresses: () async => ['127.0.0.1'],
    );
    await service.start();
    return Node._(db, repo, peers, service, name);
  }

  Future<void> stop() async {
    await service.stop();
    db.close();
  }
}

void main() {
  late Node a;
  late Node b;
  setUp(() async {
    a = await Node.start('Laptop');
    b = await Node.start('Phone');
  });
  tearDown(() async {
    await a.stop();
    await b.stop();
  });

  group('TcpTransport', () {
    test('frames survive being split and merged by TCP', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final got = <Uint8List>[];
      final done = server.first.then((s) async {
        final t = TcpTransport(s);
        for (var i = 0; i < 3; i++) {
          got.add(await t.receive());
        }
        await t.send(Uint8List.fromList([9, 9]));
      });
      final raw = await Socket.connect('127.0.0.1', server.port);
      // Frame 1 split mid-header, frames 2 and 3 in a single write.
      Uint8List frame(List<int> d) =>
          Uint8List.fromList([0, 0, 0, d.length, ...d]);
      final f1 = frame(List.generate(50, (i) => i));
      raw.add(f1.sublist(0, 2));
      await raw.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      raw.add(f1.sublist(2));
      raw.add([
        ...frame([1, 2, 3]),
        ...frame([]),
      ]);
      await raw.flush();
      await done;
      expect(got[0], List.generate(50, (i) => i));
      expect(got[1], [1, 2, 3]);
      expect(got[2], isEmpty);
      await raw.close();
    });

    test(
      'an absurd length prefix closes the connection instead of allocating',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final result = server.first.then((s) async {
          final t = TcpTransport(s);
          try {
            await t.receive();
            return 'received';
          } on TransportClosed {
            return 'closed';
          }
        });
        final raw = await Socket.connect('127.0.0.1', server.port);
        raw.add([0xFF, 0xFF, 0xFF, 0xFF]);
        await raw.flush();
        expect(await result, 'closed');
        raw.destroy();
      },
    );
  });

  group('pairing codes', () {
    test(
      'round trip, and bad input is explained rather than thrown as a crash',
      () {
        final host = PairingHost();
        final code = host.code(
          deviceId: newDeviceId(),
          deviceName: 'Laptop',
          endpoints: ['192.168.1.5:47380', '100.64.1.2:47380'],
        );
        final back = PairingCode.decode(code.encode());
        expect(back.deviceId, code.deviceId);
        expect(back.endpoints, code.endpoints);
        expect(back.secret, code.secret);
        expect(back.expired, isFalse);
        for (final bad in [
          '',
          'hello',
          'notes-pair:1:%%%',
          'notes-pair:1:${base64Url.encode(utf8.encode('{"id":"x"}'))}',
        ]) {
          expect(
            () => PairingCode.decode(bad),
            throwsFormatException,
            reason: bad,
          );
        }
      },
    );

    test(
      'an offer works once, expires, and is withdrawn after repeated failures',
      () {
        var now = DateTime(2026, 1, 1, 12);
        final h = PairingHost(
          lifetime: const Duration(minutes: 5),
          now: () => now,
        );
        expect(h.lookup(h.offer.id), isNotNull);
        h.consume();
        expect(h.lookup(h.offer.id), isNull);
        final h2 = PairingHost(
          lifetime: const Duration(minutes: 5),
          now: () => now,
        );
        now = now.add(const Duration(minutes: 6));
        expect(h2.active, isFalse);
        now = DateTime(2026, 1, 1, 12);
        final h3 = PairingHost(
          lifetime: const Duration(minutes: 5),
          now: () => now,
        );
        for (var i = 0; i < PairingHost.maxAttempts; i++) {
          h3.lookup(randomBytes(8));
          h3.lookup(h3.offer.id);
        }
        expect(h3.active, isFalse);
      },
    );
  });

  test('pair over real sockets, then sync both ways', () async {
    final code = await a.service.beginPairing();
    final peerOfA = await b.service.pairWith(PairingCode.decode(code.encode()));
    expect(peerOfA.id, a.id);
    expect(peerOfA.name, 'Laptop');
    // The host side learns about the new device too.
    await a.service.onPaired.first.timeout(const Duration(seconds: 3));
    expect(a.peers.get(b.id)!.name, 'Phone');
    expect(a.peers.get(b.id)!.publicKey, b.service.identity.publicKey);
    expect(a.service.pairing, isNull, reason: 'the code is spent');

    a.repo.createNote(title: 'from laptop', body: body('hello'));
    b.repo.createNote(title: 'from phone', body: body('world'));
    final out = await b.service.syncPeer(a.id);
    expect(out, isNotNull, reason: b.service.lastError.toString());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      {for (final n in a.repo.listNotes()) n.title},
      {'from laptop', 'from phone'},
    );
    expect(
      {for (final n in b.repo.listNotes()) n.title},
      {'from laptop', 'from phone'},
    );
    expect(b.peers.get(a.id)!.lastSyncAt, isNotNull);
    expect(b.service.lastError, isEmpty);
    // The address that worked is remembered.
    expect(b.peers.get(a.id)!.endpoints.first, '127.0.0.1:${a.service.port}');

    // A further sync from the other side works through the stored address.
    a.repo.createNote(title: 'later', body: body('later'));
    expect(a.peers.get(b.id)!.endpoints.first, '127.0.0.1:${b.service.port}');
    final back = await a.service.syncPeer(b.id);
    expect(back, isNotNull, reason: a.service.lastError.toString());
    expect(b.repo.listNotes().any((n) => n.title == 'later'), isTrue);
  });

  test(
    'simultaneous sync requests resolve the collision and both complete',
    () async {
      final code = await a.service.beginPairing();
      await b.service.pairWith(PairingCode.decode(code.encode()));
      await a.service.onPaired.first.timeout(const Duration(seconds: 3));
      a.repo.createNote(title: 'from laptop', body: body('offline edit A'));
      b.repo.createNote(title: 'from phone', body: body('offline edit B'));

      final startTogether = Completer<void>();
      final requests = Future.wait<SyncOutcome?>([
        (() async {
          await startTogether.future;
          return a.service.syncPeer(b.id);
        })(),
        (() async {
          await startTogether.future;
          return b.service.syncPeer(a.id);
        })(),
      ]);
      startTogether.complete();
      final outcomes = await requests;
      await _quiet(a, b);

      expect(outcomes.every((outcome) => outcome is SyncOutcome), isTrue);
      expect(a.repo.listNotes().map((note) => note.title).toSet(), {
        'from laptop',
        'from phone',
      });
      expect(b.repo.listNotes().map((note) => note.title).toSet(), {
        'from laptop',
        'from phone',
      });
      expect(a.service.lastError, isEmpty);
      expect(b.service.lastError, isEmpty);
      expect(a.peers.get(b.id)!.lastError, isNull);
      expect(b.peers.get(a.id)!.lastError, isNull);
      expect(a.service.lastOutcome[b.id], isA<SyncOutcome>());
      expect(b.service.lastOutcome[a.id], isA<SyncOutcome>());
      // Rows a device applied from its peer still count as unconfirmed until a
      // later session acknowledges them; a second sync settles both sides and
      // must be quiet (idempotent).
      expect(await a.service.syncPeer(b.id), isA<SyncOutcome>());
      await _quiet(a, b);
      expect(a.peers.pendingFor(b.id), 0);
      expect(b.peers.pendingFor(a.id), 0);
      expect(a.service.syncing, isFalse);
      expect(b.service.syncing, isFalse);
      expect(a.service.currentPeerName, isNull);
      expect(b.service.currentPeerName, isNull);

      final nonDesignated = shouldDial(a.id, b.id) ? b : a;
      var observedStart = false;
      final autoSyncFinished = Completer<void>();
      nonDesignated.service.addListener(() {
        if (nonDesignated.service.currentPeerName != null) {
          observedStart = true;
        } else if (observedStart && !nonDesignated.service.syncing) {
          if (!autoSyncFinished.isCompleted) autoSyncFinished.complete();
        }
      });
      nonDesignated.service.requestAutoSync();
      await autoSyncFinished.future.timeout(const Duration(seconds: 3));
      expect(nonDesignated.service.lastError, isEmpty);
      expect(
        nonDesignated.peers
            .get(identical(nonDesignated, a) ? b.id : a.id)!
            .lastError,
        isNull,
      );
    },
  );

  test('only the non-designated device calling syncPeer still syncs', () async {
    final code = await a.service.beginPairing();
    await b.service.pairWith(PairingCode.decode(code.encode()));
    await a.service.onPaired.first.timeout(const Duration(seconds: 3));
    final designated = shouldDial(a.id, b.id) ? a : b;
    final nonDesignated = identical(designated, a) ? b : a;
    designated.repo.createNote(title: 'designated', body: body('from D'));
    nonDesignated.repo.createNote(
      title: 'non-designated',
      body: body('from N'),
    );

    final outcome = await nonDesignated.service.syncPeer(designated.id);
    await _quiet(a, b);

    expect(
      outcome,
      isNotNull,
      reason: nonDesignated.service.lastError.toString(),
    );
    for (final node in [a, b]) {
      expect(
        {for (final note in node.repo.listNotes()) note.title},
        {'designated', 'non-designated'},
      );
      expect(node.service.lastError, isEmpty);
      expect(
        node.peers.get(identical(node, a) ? b.id : a.id)!.lastError,
        isNull,
      );
      expect(node.service.syncing, isFalse);
    }
  });

  test('local edit during a session is sent in one follow-up sync', () async {
    final code = await a.service.beginPairing();
    await b.service.pairWith(PairingCode.decode(code.encode()));
    await a.service.onPaired.first.timeout(const Duration(seconds: 3));

    final original = a.repo.createNote(
      title: 'edit during sync',
      body: body('original'),
    );
    b.repo.createNote(title: 'peer commit', body: body('committed'));

    final edited = Completer<void>();
    final delivered = Completer<void>();
    var editStarted = false;
    void injectEdit() {
      if (editStarted ||
          !a.repo.listNotes().any((note) => note.title == 'peer commit')) {
        return;
      }
      editStarted = true;
      final current = a.repo.getRecord(original.id)!;
      a.repo.saveContent(
        original.id,
        title: 'edited during sync',
        body: body('updated after the peer commit'),
        base: current.contentVv,
      );
      edited.complete();
    }

    void observeDelivery() {
      if (b.repo.getRecord(original.id)?.body ==
              body('updated after the peer commit') &&
          !delivered.isCompleted) {
        delivered.complete();
      }
    }

    a.repo.changes.addListener(injectEdit);
    addTearDown(() => a.repo.changes.removeListener(injectEdit));
    b.repo.changes.addListener(observeDelivery);
    addTearDown(() => b.repo.changes.removeListener(observeDelivery));
    var sessionActive = false;
    var sessionStarts = 0;
    a.service.addListener(() {
      final active = a.service.currentPeerName != null;
      if (active && !sessionActive) sessionStarts++;
      sessionActive = active;
    });

    final starter = shouldDial(a.id, b.id) ? a : b;
    final other = identical(starter, a) ? b : a;
    await starter.service.syncPeer(other.id);
    await edited.future.timeout(const Duration(seconds: 3));
    a.repo.changes.removeListener(injectEdit);
    await delivered.future.timeout(const Duration(seconds: 3));
    await _quiet(a, b);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      b.repo.getRecord(original.id)!.body,
      body('updated after the peer commit'),
    );
    expect(sessionStarts, greaterThanOrEqualTo(2));
    expect(sessionStarts, lessThan(4), reason: 'follow-up syncing must settle');
    expect(a.service.syncing, isFalse);
    expect(b.service.syncing, isFalse);
  });

  test('only the designated device calling syncPeer still syncs', () async {
    final code = await a.service.beginPairing();
    await b.service.pairWith(PairingCode.decode(code.encode()));
    await a.service.onPaired.first.timeout(const Duration(seconds: 3));
    final designated = shouldDial(a.id, b.id) ? a : b;
    final nonDesignated = identical(designated, a) ? b : a;
    designated.repo.createNote(title: 'designated', body: body('from D'));
    nonDesignated.repo.createNote(
      title: 'non-designated',
      body: body('from N'),
    );

    final outcome = await designated.service.syncPeer(nonDesignated.id);
    await _quiet(a, b);

    expect(outcome, isNotNull, reason: designated.service.lastError.toString());
    for (final node in [a, b]) {
      expect(
        {for (final note in node.repo.listNotes()) note.title},
        {'designated', 'non-designated'},
      );
      expect(node.service.lastError, isEmpty);
      expect(
        node.peers.get(identical(node, a) ? b.id : a.id)!.lastError,
        isNull,
      );
      expect(node.service.syncing, isFalse);
    }
  });

  test('a used pairing code cannot be used again', () async {
    final code = await a.service.beginPairing();
    await b.service.pairWith(code);
    final c = await Node.start('Tablet');
    addTearDown(c.stop);
    await expectLater(c.service.pairWith(code), throwsA(isA<PairingFailure>()));
    expect(a.peers.list().map((p) => p.id), [b.id]);
    expect(c.peers.list(), isEmpty);
  });

  test(
    'an expired code or one from this device is refused before any network use',
    () async {
      final host = PairingHost(lifetime: const Duration(seconds: -1));
      final old = host.code(
        deviceId: a.id,
        deviceName: 'Laptop',
        endpoints: ['127.0.0.1:${a.service.port}'],
      );
      await expectLater(
        b.service.pairWith(old),
        throwsA(isA<PairingFailure>()),
      );
      final own = await b.service.beginPairing();
      await expectLater(
        b.service.pairWith(own),
        throwsA(isA<PairingFailure>()),
      );
    },
  );

  test(
    'pairing is refused cleanly when one side is full, and nothing is stored',
    () async {
      for (var i = 0; i < maxDevices - 1; i++) {
        a.peers.add(id: newDeviceId(), name: 'D$i', publicKey: randomBytes(32));
      }
      final code = await a.service.beginPairing();
      await expectLater(
        b.service.pairWith(code),
        throwsA(isA<PairingFailure>()),
      );
      expect(b.peers.list(), isEmpty);
      expect(a.peers.list().length, maxDevices - 1);
    },
  );

  test('an unreachable device gives a plain message, backs off, and keeps local data safe', () async {
    final code = await a.service.beginPairing();
    await b.service.pairWith(code);
    await a.service.onPaired.first.timeout(const Duration(seconds: 3));
    await a.service.stop(); // laptop goes away
    b.repo.createNote(title: 'offline note', body: body('still works'));
    final out = await b.service.syncPeer(a.id);
    expect(out, isNull);
    expect(b.service.lastError[a.id], contains('not reachable'));
    expect(b.peers.get(a.id)!.lastError, isNotNull);
    expect(b.repo.listNotes().single.title, 'offline note');
    expect(
      b.peers.pendingFor(a.id),
      1,
      reason: 'the change stays queued for the next time',
    );
  });

  test('a removed device is refused by the one that removed it', () async {
    final code = await a.service.beginPairing();
    await b.service.pairWith(code);
    await a.service.onPaired.first.timeout(const Duration(seconds: 3));
    a.peers.remove(b.id);
    final out = await b.service.syncPeer(a.id);
    expect(out, isNull);
    expect(b.service.lastError[a.id], isNotNull);
    expect(a.repo.listNotes(), isEmpty);
  });

  test('removing a peer closes its paused incoming session', () async {
    final code = await a.service.beginPairing();
    await b.service.pairWith(code);
    await a.service.onPaired.first.timeout(const Duration(seconds: 3));
    final note = b.repo.createNote(
      id: 'paused-removed-peer',
      title: 'must not arrive',
      body: body('queued before removal'),
    );
    final transport = await TcpTransport.connect('127.0.0.1', a.service.port);
    final channel = await SecureChannel.initiateSession(
      transport,
      myId: b.id,
      identity: b.service.identity,
      peerId: a.id,
      peerPublicKey: a.service.identity.publicKey,
    );
    final messages = MessageStream(channel);
    await messages.send({
      't': 'hello',
      'proto': 1,
      'id': b.id,
      'name': b.name,
      'schema': 3,
      'from': 0,
      'max': 1,
    });
    await messages.expect('hello');
    await messages.expect('done');
    await messages.send({
      't': 'rows',
      'k': 'notes',
      'rows': [b.repo.getRecord(note.id)!.toJson()],
    });

    a.service.removePeer(b.id);

    await expectLater(channel.receive(), throwsA(isA<TransportClosed>()));
    expect(a.repo.getRecord(note.id), isNull);
    expect(a.service.lastError, isEmpty);
    await channel.close();
  });

  test('a stranger who never paired cannot sync, and cannot read anything', () async {
    final stranger = await Node.start('Stranger');
    addTearDown(stranger.stop);
    a.repo.createNote(title: 'private', body: body('secret'));
    // The stranger invents a peer entry pointing at A with A's real public key,
    // but A has never heard of the stranger.
    stranger.peers.add(
      id: a.id,
      name: 'Laptop',
      publicKey: a.service.identity.publicKey,
      endpoints: ['127.0.0.1:${a.service.port}'],
    );
    final out = await stranger.service.syncPeer(a.id);
    expect(out, isNull);
    expect(stranger.repo.listNotes(), isEmpty);
  });

  test('auto sync skips devices that failed recently', () async {
    final code = await a.service.beginPairing();
    await b.service.pairWith(code);
    await a.service.onPaired.first.timeout(const Duration(seconds: 3));
    await a.service.stop();
    await b.service.syncPeer(a.id); // fails, schedules a back-off
    await a.service.start();
    // Port changed after the restart; the stored endpoint is now wrong.
    var attempts = 0;
    b.service.addListener(() => attempts++);
    b.service.requestAutoSync();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(attempts, 0, reason: 'inside the back-off window nothing is tried');
  });

  test('describeEndpoint recognises Tailscale addresses', () {
    expect(
      describeEndpoint('100.101.102.103:47380'),
      'Tailscale 100.101.102.103',
    );
    expect(describeEndpoint('192.168.1.5:47380'), '192.168.1.5');
    expect(describeEndpoint('100.30.1.1:47380'), '100.30.1.1');
  });

  test('two people holding the same code cannot both pair', () async {
    final code = await a.service.beginPairing();
    final c = await Node.start('Tablet');
    addTearDown(c.stop);
    final paired = a.service.onPaired.first.timeout(const Duration(seconds: 3));
    final results = await Future.wait([
      b.service.pairWith(code).then<Object>((p) => p, onError: (Object e) => e),
      c.service.pairWith(code).then<Object>((p) => p, onError: (Object e) => e),
    ]);
    final succeeded = results.whereType<Peer>().length;
    expect(succeeded, 1, reason: '$results');
    await paired; // the host finishes its side a moment later
    expect(a.peers.list().length, 1);
  });

  test(
    'strangers cannot use up the connection slots, and slots are freed',
    () async {
      final n = await Node.start(
        'Host',
        handshakeTimeout: const Duration(milliseconds: 500),
      );
      addTearDown(n.stop);
      final idle = <Socket>[];
      for (var i = 0; i < 2; i++) {
        idle.add(await Socket.connect('127.0.0.1', n.service.port));
      }
      // A third connection from the same address is refused straight away.
      final third = await Socket.connect('127.0.0.1', n.service.port);
      var thirdClosed = false;
      third.listen(
        (_) {},
        onDone: () => thirdClosed = true,
        onError: (Object _) => thirdClosed = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(thirdClosed, isTrue);
      // Idle ones are dropped by the handshake timeout, freeing the slots.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final again = await Socket.connect('127.0.0.1', n.service.port);
      var againClosed = false;
      again.listen(
        (_) {},
        onDone: () => againClosed = true,
        onError: (Object _) => againClosed = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        againClosed,
        isFalse,
        reason: 'a fresh connection is accepted once the slots are free',
      );
      for (final s in [...idle, third, again]) {
        s.destroy();
      }
    },
  );

  test('a fast sender and a slow reader: data is held back by TCP, not lost or dropped', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    const frames = 14;
    final received = <int>[];
    final done = server.first.then((sock) async {
      final t = TcpTransport(sock);
      for (var i = 0; i < frames; i++) {
        final f = await t.receive();
        received.add(f.length);
        await Future<void>.delayed(
          const Duration(milliseconds: 15),
        ); // slow reader
      }
    });
    final client = TcpTransport(await Socket.connect('127.0.0.1', server.port));
    for (var i = 0; i < frames; i++) {
      await client.send(Uint8List(900 * 1024));
    }
    await done.timeout(const Duration(seconds: 20));
    expect(received, List.filled(frames, 900 * 1024));
    await client.close();
  });
}
