import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/sync/peers.dart';
import 'package:notes/sync/secure_channel.dart';

import '../support/memory_transport.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// A side that failed to connect either reports why or finds the other side
/// has hung up on it.
final failed = anyOf(isA<HandshakeException>(), isA<TransportClosed>());

Peer peerOf(String id, DeviceIdentity i) => Peer(
  id: id,
  name: id,
  publicKey: i.publicKey,
  addedAt: 0,
  endpoints: const [],
  lastSyncAt: null,
  lastError: null,
  sentCursor: 0,
  recvCursor: 0,
);

void main() {
  late String idA;
  late String idB;
  late DeviceIdentity a;
  late DeviceIdentity b;
  setUp(() async {
    idA = newDeviceId();
    idB = newDeviceId();
    a = await DeviceIdentity.fromPrivate(randomBytes(32));
    b = await DeviceIdentity.fromPrivate(randomBytes(32));
  });

  Future<(SecureChannel, SecureChannel)> connect(
    MemoryEnd ta,
    MemoryEnd tb, {
    DeviceIdentity? aThinksBIs,
    Peer? Function(String)? lookup,
  }) async {
    final results = await Future.wait([
      SecureChannel.initiateSession(
        ta,
        myId: idA,
        identity: a,
        peerId: idB,
        peerPublicKey: (aThinksBIs ?? b).publicKey,
      ),
      SecureChannel.respond(
        tb,
        myId: idB,
        identity: b,
        lookupPeer: lookup ?? (id) => id == idA ? peerOf(idA, a) : null,
        lookupOffer: (_) => null,
      ),
    ]);
    return (results[0], results[1]);
  }

  test('paired devices talk both ways, many messages, each side knows who it is talking to', () async {
    final (ta, tb) = MemoryEnd.pair();
    final (ca, cb) = await connect(ta, tb);
    expect(ca.peerId, idB);
    expect(cb.peerId, idA);
    for (var i = 0; i < 20; i++) {
      await ca.send(bytes('to B $i'));
      expect(utf8.decode(await cb.receive()), 'to B $i');
      await cb.send(bytes('to A $i'));
      expect(utf8.decode(await ca.receive()), 'to A $i');
    }
    await ca.send(Uint8List(0));
    expect(await cb.receive(), isEmpty);
    await ca.send(Uint8List(maxMessageBytes));
    expect((await cb.receive()).length, maxMessageBytes);
  });

  test('nothing readable crosses the wire', () async {
    final (ta, tb) = MemoryEnd.pair();
    final (ca, cb) = await connect(ta, tb);
    await ca.send(bytes('very secret note text'));
    await cb.receive();
    for (final f in [...ta.sent, ...tb.sent]) {
      expect(utf8.decode(f, allowMalformed: true), isNot(contains('secret')));
    }
  });

  test('a tampered frame is rejected and ends the channel', () async {
    final (ta, tb) = MemoryEnd.pair();
    final (ca, cb) = await connect(ta, tb);
    ta.filter = (f, _) => [Uint8List.fromList(f)..[3] ^= 0x01];
    await ca.send(bytes('hello'));
    await expectLater(cb.receive(), throwsA(isA<ChannelIntegrityException>()));
    await expectLater(cb.receive(), throwsA(isA<ChannelIntegrityException>()));
  });

  test('a replayed frame is rejected', () async {
    final (ta, tb) = MemoryEnd.pair();
    final (ca, cb) = await connect(ta, tb);
    ta.filter = (f, _) => [f, f]; // delivered twice
    await ca.send(bytes('pay once'));
    expect(utf8.decode(await cb.receive()), 'pay once');
    await expectLater(cb.receive(), throwsA(isA<ChannelIntegrityException>()));
  });

  test('a dropped or reordered frame is detected', () async {
    final (ta, tb) = MemoryEnd.pair();
    final (ca, cb) = await connect(ta, tb);
    ta.filter = (f, i) =>
        i == ta.sent.length - 1 && i % 2 == 0 ? const [] : [f];
    final before = ta.sent.length;
    ta.filter = (f, i) => i == before ? const [] : [f];
    await ca.send(bytes('one')); // dropped
    await ca.send(bytes('two'));
    await expectLater(cb.receive(), throwsA(isA<ChannelIntegrityException>()));
  });

  test('a frame recorded in one session does not work in another', () async {
    final (ta1, tb1) = MemoryEnd.pair();
    final (ca1, cb1) = await connect(ta1, tb1);
    await ca1.send(bytes('first session'));
    await cb1.receive();
    final recorded = ta1.sent.last;
    final (ta2, tb2) = MemoryEnd.pair();
    final (_, cb2) = await connect(ta2, tb2);
    ta2.inject(recorded);
    await expectLater(cb2.receive(), throwsA(isA<ChannelIntegrityException>()));
  });

  test('a frame reflected back at its sender is rejected', () async {
    final (ta, tb) = MemoryEnd.pair();
    final (ca, _) = await connect(ta, tb);
    await ca.send(bytes('mirror'));
    tb.inject(ta.sent.last); // attacker bounces A's own frame back to A
    await expectLater(ca.receive(), throwsA(isA<ChannelIntegrityException>()));
  });

  test('an impostor without the right private key cannot complete the handshake', () async {
    final (ta, tb) = MemoryEnd.pair();
    final mallory = await DeviceIdentity.fromPrivate(randomBytes(32));
    // A believes it is talking to B (knows B's key); the responder is Mallory.
    final r = await Future.wait([
      SecureChannel.initiateSession(
        ta,
        myId: idA,
        identity: a,
        peerId: idB,
        peerPublicKey: b.publicKey,
      ).then<Object>((c) => c, onError: (e) => e as Object),
      SecureChannel.respond(
        tb,
        myId: idB,
        identity: mallory,
        lookupPeer: (id) => peerOf(idA, a),
        lookupOffer: (_) => null,
      ).then<Object>((c) => c, onError: (e) => e as Object),
    ]);
    expect(r[0], failed);
    expect(r[1], failed);
  });

  test(
    'an unknown or unpaired device is turned away before any key work',
    () async {
      final (ta, tb) = MemoryEnd.pair();
      final r = await Future.wait([
        SecureChannel.initiateSession(
          ta,
          myId: idA,
          identity: a,
          peerId: idB,
          peerPublicKey: b.publicKey,
        ).then<Object>((c) => c, onError: (e) => e as Object),
        SecureChannel.respond(
          tb,
          myId: idB,
          identity: b,
          lookupPeer: (_) => null,
          lookupOffer: (_) => null,
        ).then<Object>(
          (c) => c,
          onError: (e) {
            tb.close();
            return e as Object;
          },
        ),
      ]);
      expect(r[1], isA<HandshakeException>());
      expect(r[0], isA<TransportClosed>());
    },
  );

  test(
    'a stored key that no longer matches (device reinstalled) fails cleanly',
    () async {
      final (ta, tb) = MemoryEnd.pair();
      final reinstalled = await DeviceIdentity.fromPrivate(randomBytes(32));
      final r = await Future.wait([
        SecureChannel.initiateSession(
          ta,
          myId: idA,
          identity: a,
          peerId: idB,
          peerPublicKey: b.publicKey,
        ).then<Object>((c) => c, onError: (e) => e as Object),
        SecureChannel.respond(
          tb,
          myId: idB,
          identity: reinstalled,
          lookupPeer: (id) => peerOf(idA, a),
          lookupOffer: (_) => null,
        ).then<Object>((c) => c, onError: (e) => e as Object),
      ]);
      expect(r[0], isA<HandshakeException>());
    },
  );

  group('pairing with a one-time code', () {
    late PairingOffer offer;
    setUp(() {
      offer = PairingOffer(
        id: randomBytes(8),
        secret: randomBytes(32),
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );
    });

    Future<List<Object>> run(
      Uint8List secretUsedByScanner, {
      PairingOffer? served,
      DateTime Function()? now,
    }) {
      final (ta, tb) = MemoryEnd.pair();
      return Future.wait([
        SecureChannel.initiatePairing(
          ta,
          myId: idA,
          peerId: idB,
          offerId: offer.id,
          offerSecret: secretUsedByScanner,
        ).then<Object>((c) => c, onError: (e) => e as Object),
        SecureChannel.respond(
          tb,
          myId: idB,
          identity: b,
          lookupPeer: (_) => null,
          lookupOffer: (id) => served ?? offer,
          now: now,
        ).then<Object>(
          (c) => c,
          onError: (e) {
            tb.close();
            return e as Object;
          },
        ),
      ]);
    }

    test('the right code pairs, and messages flow', () async {
      final r = await run(offer.secret);
      final ca = r[0] as SecureChannel;
      final cb = r[1] as SecureChannel;
      expect(ca.mode, HandshakeMode.pairing);
      expect(cb.peerId, idA);
      await ca.send(bytes('my public key goes here'));
      expect(utf8.decode(await cb.receive()), 'my public key goes here');
    });

    test('a wrong code is refused on both sides', () async {
      final r = await run(randomBytes(32));
      expect(r[0], failed);
      expect(r[1], failed);
    });

    test('an expired offer is refused', () async {
      final r = await run(
        offer.secret,
        now: () => DateTime.now().add(const Duration(hours: 1)),
      );
      expect(r[1], isA<HandshakeException>());
    });

    test('an unknown offer id is refused', () async {
      final (ta, tb) = MemoryEnd.pair();
      final r = await Future.wait([
        SecureChannel.initiatePairing(
          ta,
          myId: idA,
          peerId: idB,
          offerId: randomBytes(8),
          offerSecret: offer.secret,
        ).then<Object>((c) => c, onError: (e) => e as Object),
        SecureChannel.respond(
          tb,
          myId: idB,
          identity: b,
          lookupPeer: (_) => null,
          lookupOffer: (_) => null,
        ).then<Object>(
          (c) => c,
          onError: (e) {
            tb.close();
            return e as Object;
          },
        ),
      ]);
      expect(r[1], isA<HandshakeException>());
    });
  });

  group('malformed and mismatched input', () {
    test(
      'garbage and truncated handshakes are rejected, not crashed on',
      () async {
        final junkList = [
          Uint8List(0),
          Uint8List(5),
          randomBytes(69),
          randomBytes(71),
          Uint8List.fromList([
            0x4E,
            0x54,
            0x53,
            0x31,
            1,
            0,
            ...List.filled(64, 0),
          ]),
          Uint8List.fromList([
            0x4E,
            0x54,
            0x53,
            0x31,
            1,
            9,
            ...List.filled(64, 0),
          ]),
        ];
        for (final junk in junkList) {
          final (ta, tb) = MemoryEnd.pair();
          await ta.send(junk);
          await expectLater(
            SecureChannel.respond(
              tb,
              myId: idB,
              identity: b,
              lookupPeer: (_) => null,
              lookupOffer: (_) => null,
            ),
            throwsA(isA<HandshakeException>()),
          );
        }
      },
    );

    test(
      'a peer on another protocol version is reported with its version',
      () async {
        final (ta, tb) = MemoryEnd.pair();
        final r = await Future.wait([
          // Hand-built hello from a "version 2" device.
          () async {
            final m = Uint8List.fromList([
              0x4E,
              0x54,
              0x53,
              0x31,
              2,
              0,
              ...List.filled(8 + 8 + 32 + 16, 1),
            ]);
            await ta.send(m);
            return ta.receive();
          }().then<Object>((f) => f, onError: (e) => e as Object),
          SecureChannel.respond(
            tb,
            myId: idB,
            identity: b,
            lookupPeer: (_) => null,
            lookupOffer: (_) => null,
          ).then<Object>((c) => c, onError: (e) => e as Object),
        ]);
        expect(r[1], isA<HandshakeException>());
        expect((r[1] as HandshakeException).peerVersion, 2);
        expect((r[0] as Uint8List)[4], secureChannelVersion);
      },
    );

    test(
      'oversized messages are refused locally and oversized frames remotely',
      () async {
        final (ta, tb) = MemoryEnd.pair();
        final (ca, cb) = await connect(ta, tb);
        expect(
          () => ca.send(Uint8List(maxMessageBytes + 1)),
          throwsArgumentError,
        );
        ta.inject(Uint8List(maxMessageBytes + 1000));
        tb.inject(Uint8List(maxMessageBytes + 1000));
        await expectLater(
          cb.receive(),
          throwsA(isA<ChannelIntegrityException>()),
        );
      },
    );
  });
}
