import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/pairing.dart';
import 'package:notes/sync/peers.dart';
import 'package:notes/sync/secure_channel.dart';
import 'package:notes/sync/sync_service.dart';
import 'package:notes/sync/tcp_transport.dart';

String body(String t) => jsonEncode([
  {'insert': '$t\n'},
]);

class Node {
  Node._(this.db, this.repo, this.peers, this.service, this.name);
  final AppDatabase db;
  final NoteRepository repo;
  final PeerStore peers;
  final SyncService service;
  final String name;
  String get id => db.deviceId;

  static Future<Node> start(String name) async {
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
}
