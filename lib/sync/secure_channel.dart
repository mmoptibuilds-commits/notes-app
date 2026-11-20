import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

import '../core/ids.dart';
import 'peers.dart';

/// Moves whole frames (byte strings) between two devices, in order, without
/// loss or duplication, like a TCP connection with message boundaries.
/// Everything above is encrypted and authenticated; the transport is
/// untrusted.
abstract interface class FrameTransport {
  Future<void> send(Uint8List frame);

  /// The next frame. Throws [TransportClosed] when the other side is gone.
  Future<Uint8List> receive();

  Future<void> close();
}

class TransportClosed implements Exception {
  TransportClosed([this.reason = 'connection closed']);
  final String reason;
  @override
  String toString() => 'TransportClosed: $reason';
}

/// The handshake did not complete: the other side is not who it should be,
/// speaks another version, or sent something malformed.
class HandshakeException implements Exception {
  HandshakeException(this.message, {this.peerVersion});
  final String message;

  /// Protocol version the other side offered, if it said.
  final int? peerVersion;
  @override
  String toString() => 'HandshakeException: $message';
}

/// A frame failed authentication, arrived out of order, or was replayed. The
/// channel is closed; nothing from the frame is used.
class ChannelIntegrityException implements Exception {
  ChannelIntegrityException(this.message);
  final String message;
  @override
  String toString() => 'ChannelIntegrityException: $message';
}

enum HandshakeMode { session, pairing }

/// A one-time pairing offer shown to the other device as a QR code.
class PairingOffer {
  PairingOffer({
    required this.id,
    required this.secret,
    required this.expiresAt,
  });

  /// Public identifier (8 bytes) the scanner sends so the right offer is
  /// found. Not secret.
  final Uint8List id;

  /// 32 random bytes shared only through the QR code.
  final Uint8List secret;
  final DateTime expiresAt;
}

const secureChannelVersion = 1;
const maxMessageBytes = 1024 * 1024;

const _magic = [0x4E, 0x54, 0x53, 0x31]; // "NTS1"
const _tagLen = 16;

final _aead = Chacha20.poly1305Aead();
final _x25519 = X25519();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);

/// An established, encrypted, authenticated connection.
///
/// Each direction has its own key. A frame's nonce is its position in the
/// stream, so a replayed, dropped, duplicated or reordered frame fails
/// authentication and ends the channel.
class SecureChannel {
  SecureChannel._(
    this._t,
    this.mode,
    this.peerId,
    this._sendKey,
    this._recvKey,
    this._binding,
  );

  final FrameTransport _t;
  final HandshakeMode mode;

  /// Device id of the other side as claimed during the handshake. In
  /// session mode it is proven (only the holder of that device's private key
  /// completes the handshake); in pairing mode it is only as trustworthy as
  /// the one-time secret, and is confirmed again inside the channel.
  final String peerId;
  final SecretKey _sendKey;
  final SecretKey _recvKey;
  final List<int> _binding;
  int _sendCounter = 1; // 0 is used by the handshake confirmations
  int _recvCounter = 1;
  bool _broken = false;

  // ------------------------------------------------------------ handshake

  /// Connects to a paired device. [peerPublicKey] is the key stored when the
  /// two were paired.
  static Future<SecureChannel> initiateSession(
    FrameTransport t, {
    required String myId,
    required DeviceIdentity identity,
    required String peerId,
    required Uint8List peerPublicKey,
  }) => _initiate(
    t,
    HandshakeMode.session,
    myId: myId,
    identity: identity,
    peerId: peerId,
    peerPublicKey: peerPublicKey,
  );

  /// Pairs with a device that is showing [offer] (decoded from its QR code).
  static Future<SecureChannel> initiatePairing(
    FrameTransport t, {
    required String myId,
    required String peerId,
    required Uint8List offerId,
    required Uint8List offerSecret,
  }) => _initiate(
    t,
    HandshakeMode.pairing,
    myId: myId,
    peerId: peerId,
    offerId: offerId,
    offerSecret: offerSecret,
  );

  static Future<SecureChannel> _initiate(
    FrameTransport t,
    HandshakeMode mode, {
    required String myId,
    required String peerId,
    DeviceIdentity? identity,
    Uint8List? peerPublicKey,
    Uint8List? offerId,
    Uint8List? offerSecret,
  }) async {
    try {
      return await _initiateInner(
        t,
        mode,
        myId: myId,
        peerId: peerId,
        identity: identity,
        peerPublicKey: peerPublicKey,
        offerId: offerId,
        offerSecret: offerSecret,
      );
    } on HandshakeException {
      await t.close(); // never leave the other side waiting
      rethrow;
    }
  }

  static Future<SecureChannel> _initiateInner(
    FrameTransport t,
    HandshakeMode mode, {
    required String myId,
    required String peerId,
    DeviceIdentity? identity,
    Uint8List? peerPublicKey,
    Uint8List? offerId,
    Uint8List? offerSecret,
  }) async {
    final eph = await _x25519.newKeyPair();
    final ephPub = (await eph.extractPublicKey()).bytes;
    final nonce = randomBytes(16);
    final m1 = BytesBuilder()
      ..add(_magic)
      ..addByte(secureChannelVersion)
      ..addByte(mode == HandshakeMode.session ? 0 : 1)
      ..add(_idBytes(myId))
      ..add(mode == HandshakeMode.pairing ? offerId! : Uint8List(8))
      ..add(ephPub)
      ..add(nonce);
    final m1Bytes = m1.toBytes();
    await t.send(m1Bytes);

    final m2 = await t.receive();
    if (m2.length >= 5 && m2[4] != secureChannelVersion && _hasMagic(m2)) {
      throw HandshakeException(
        'The other device speaks protocol version ${m2[4]}.',
        peerVersion: m2[4],
      );
    }
    if (m2.length != 4 + 1 + 8 + 32 + 16 + 4 + _tagLen || !_hasMagic(m2)) {
      throw HandshakeException('Malformed handshake reply.');
    }
    final responderId = m2.sublist(5, 13);
    if (hex(responderId) != peerId) {
      throw HandshakeException('Reply is from a different device.');
    }
    final ephR = m2.sublist(13, 45);
    final nonceR = m2.sublist(45, 61);
    final confirmR = m2.sublist(61);

    final binding = sha256Bytes([
      ...utf8.encode('notes-sync-v1'),
      ...m1Bytes,
      ...responderId,
      ...ephR,
      ...nonceR,
    ]);
    final ikm = BytesBuilder()..add(await _dh(eph, ephR));
    if (mode == HandshakeMode.session) {
      ikm
        ..add(await _dh(eph, peerPublicKey!)) // es
        ..add(await _dh(identity!.keyPair, ephR)) // se
        ..add(await _dh(identity.keyPair, peerPublicKey)); // ss
    } else {
      ikm.add(offerSecret!);
    }
    final keys = await _derive(ikm.toBytes(), binding);
    // initiator sends with the first key, receives with the second
    final sendKey = SecretKey(keys.sublist(0, 32));
    final recvKey = SecretKey(keys.sublist(32, 64));

    final ok = await _open(recvKey, 0, binding, confirmR);
    if (ok == null || utf8.decode(ok, allowMalformed: true) != 'ok-R') {
      throw HandshakeException(
        mode == HandshakeMode.session
            ? 'The other device could not be verified.'
            : 'The pairing code was not accepted.',
      );
    }
    await t.send(await _seal(sendKey, 0, binding, utf8.encode('ok-I')));
    return SecureChannel._(t, mode, peerId, sendKey, recvKey, binding);
  }

  /// Accepts an incoming connection.
  ///
  /// [lookupPeer] returns the stored key of a paired device (null if
  /// unknown); [lookupOffer] returns the live pairing offer with that id.
  /// [onSessionPeer] sees a session initiator's claimed id before its
  /// handshake proof is complete. [rejectSessionPeer] may close that session
  /// before replying to its handshake, without changing the wire protocol.
  static Future<SecureChannel> respond(
    FrameTransport t, {
    required String myId,
    required DeviceIdentity identity,
    required Peer? Function(String peerId) lookupPeer,
    required PairingOffer? Function(Uint8List offerId) lookupOffer,
    void Function(String peerId)? onSessionPeer,
    FutureOr<bool> Function(String peerId)? rejectSessionPeer,
    DateTime Function()? now,
  }) async {
    try {
      return await _respondInner(
        t,
        myId: myId,
        identity: identity,
        lookupPeer: lookupPeer,
        lookupOffer: lookupOffer,
        onSessionPeer: onSessionPeer,
        rejectSessionPeer: rejectSessionPeer,
        now: now,
      );
    } on HandshakeException {
      await t.close(); // never leave the other side waiting
      rethrow;
    }
  }

  static Future<SecureChannel> _respondInner(
    FrameTransport t, {
    required String myId,
    required DeviceIdentity identity,
    required Peer? Function(String peerId) lookupPeer,
    required PairingOffer? Function(Uint8List offerId) lookupOffer,
    void Function(String peerId)? onSessionPeer,
    FutureOr<bool> Function(String peerId)? rejectSessionPeer,
    DateTime Function()? now,
  }) async {
    final m1 = await t.receive();
    if (m1.length != 4 + 1 + 1 + 8 + 8 + 32 + 16 || !_hasMagic(m1)) {
      throw HandshakeException('Malformed handshake.');
    }
    if (m1[4] != secureChannelVersion) {
      // Tell an honest newer/older peer which version we speak. Unauthenticated
      // and advisory only.
      await t.send(Uint8List.fromList([..._magic, secureChannelVersion]));
      throw HandshakeException(
        'The other device speaks protocol version ${m1[4]}.',
        peerVersion: m1[4],
      );
    }
    final modeByte = m1[5];
    if (modeByte > 1) throw HandshakeException('Unknown handshake mode.');
    final mode = modeByte == 0 ? HandshakeMode.session : HandshakeMode.pairing;
    final initiatorIdBytes = m1.sublist(6, 14);
    final initiatorId = hex(initiatorIdBytes);
    final offerId = m1.sublist(14, 22);
    final ephI = m1.sublist(22, 54);

    Peer? peer;
    PairingOffer? offer;
    if (mode == HandshakeMode.session) {
      peer = lookupPeer(initiatorId);
      if (peer == null) {
        throw HandshakeException('Unknown device $initiatorId.');
      }
      onSessionPeer?.call(initiatorId);
      final reject = rejectSessionPeer;
      if (reject != null && await reject(initiatorId)) {
        throw HandshakeException('A sync is already in progress.');
      }
    } else {
      offer = lookupOffer(offerId);
      if (offer == null || !offer.expiresAt.isAfter((now ?? DateTime.now)())) {
        throw HandshakeException('Unknown or expired pairing code.');
      }
    }

    final eph = await _x25519.newKeyPair();
    final ephPub = (await eph.extractPublicKey()).bytes;
    final nonceR = randomBytes(16);
    final myIdBytes = _idBytes(myId);
    final binding = sha256Bytes([
      ...utf8.encode('notes-sync-v1'),
      ...m1,
      ...myIdBytes,
      ...ephPub,
      ...nonceR,
    ]);
    final ikm = BytesBuilder()..add(await _dh(eph, ephI));
    if (mode == HandshakeMode.session) {
      ikm
        ..add(await _dh(identity.keyPair, ephI)) // es (initiator's view)
        ..add(await _dh(eph, peer!.publicKey)) // se
        ..add(await _dh(identity.keyPair, peer.publicKey)); // ss
    } else {
      ikm.add(offer!.secret);
    }
    final keys = await _derive(ikm.toBytes(), binding);
    final recvKey = SecretKey(keys.sublist(0, 32)); // initiator's send key
    final sendKey = SecretKey(keys.sublist(32, 64));

    final m2 = BytesBuilder()
      ..add(_magic)
      ..addByte(secureChannelVersion)
      ..add(myIdBytes)
      ..add(ephPub)
      ..add(nonceR)
      ..add(await _seal(sendKey, 0, binding, utf8.encode('ok-R')));
    await t.send(m2.toBytes());

    final m3 = await t.receive();
    final ok = await _open(recvKey, 0, binding, m3);
    if (ok == null || utf8.decode(ok, allowMalformed: true) != 'ok-I') {
      throw HandshakeException(
        mode == HandshakeMode.session
            ? 'The other device could not be verified.'
            : 'The pairing code was not accepted.',
      );
    }
    return SecureChannel._(t, mode, initiatorId, sendKey, recvKey, binding);
  }

  // ------------------------------------------------------------- messages

  /// Sends one message (at most [maxMessageBytes]).
  Future<void> send(Uint8List message) async {
    if (_broken) throw ChannelIntegrityException('channel is closed');
    if (message.length > maxMessageBytes) {
      throw ArgumentError.value(message.length, 'message', 'too large');
    }
    final frame = await _seal(_sendKey, _sendCounter++, _binding, message);
    await _t.send(frame);
  }

  /// The next message. Throws [ChannelIntegrityException] if the frame was
  /// tampered with, replayed or out of order, and [TransportClosed] when the
  /// other side hangs up.
  Future<Uint8List> receive() async {
    if (_broken) throw ChannelIntegrityException('channel is closed');
    final frame = await _t.receive();
    if (frame.length < _tagLen || frame.length > maxMessageBytes + _tagLen) {
      _broken = true;
      await _t.close();
      throw ChannelIntegrityException('frame has an impossible size');
    }
    final plain = await _open(_recvKey, _recvCounter, _binding, frame);
    if (plain == null) {
      _broken = true;
      await _t.close();
      throw ChannelIntegrityException(
        'frame failed authentication (tampered, replayed or out of order)',
      );
    }
    _recvCounter++;
    return plain;
  }

  Future<void> close() {
    _broken = true;
    return _t.close();
  }

  // -------------------------------------------------------------- helpers

  static bool _hasMagic(Uint8List b) =>
      b.length >= 4 &&
      b[0] == _magic[0] &&
      b[1] == _magic[1] &&
      b[2] == _magic[2] &&
      b[3] == _magic[3];

  static Uint8List _idBytes(String id) {
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must be 16 hex characters');
    }
    return Uint8List.fromList([
      for (var i = 0; i < 16; i += 2)
        int.parse(id.substring(i, i + 2), radix: 16),
    ]);
  }

  static List<int> sha256Bytes(List<int> data) => sha256.convert(data).bytes;

  static List<int> _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, counter, Endian.big);
    return n;
  }

  static Future<Uint8List> _seal(
    SecretKey key,
    int counter,
    List<int> aad,
    List<int> plain,
  ) async {
    final box = await _aead.encrypt(
      plain,
      secretKey: key,
      nonce: _nonce(counter),
      aad: aad,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  /// Decrypts a frame; null if it does not authenticate.
  static Future<Uint8List?> _open(
    SecretKey key,
    int counter,
    List<int> aad,
    List<int> frame,
  ) async {
    if (frame.length < _tagLen) return null;
    final box = SecretBox(
      frame.sublist(0, frame.length - _tagLen),
      nonce: _nonce(counter),
      mac: Mac(frame.sublist(frame.length - _tagLen)),
    );
    try {
      return Uint8List.fromList(
        await _aead.decrypt(box, secretKey: key, aad: aad),
      );
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  static Future<List<int>> _dh(KeyPair mine, List<int> theirPublic) async {
    if (theirPublic.length != 32) {
      throw HandshakeException('Malformed public key.');
    }
    final shared = await _x25519.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(theirPublic, type: KeyPairType.x25519),
    );
    final bytes = await shared.extractBytes();
    // An all-zero result means the other side sent a low-order point.
    if (bytes.every((b) => b == 0)) {
      throw HandshakeException('Rejected an invalid public key.');
    }
    return bytes;
  }

  static Future<List<int>> _derive(List<int> ikm, List<int> binding) async {
    final key = await _hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: binding,
      info: utf8.encode('notes-sync v1 keys'),
    );
    return key.extractBytes();
  }
}
