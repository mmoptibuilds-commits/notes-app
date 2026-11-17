import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'peers.dart';
import 'protocol.dart';
import 'secure_channel.dart';

/// What the QR code carries: how to reach the device and the one-time secret
/// that authenticates the pairing. Anyone who sees the code while it is valid
/// can pair, so it is short-lived and works once.
class PairingCode {
  PairingCode({
    required this.deviceId,
    required this.deviceName,
    required this.offerId,
    required this.secret,
    required this.expiresAt,
    required this.endpoints,
  });

  final String deviceId;
  final String deviceName;
  final Uint8List offerId;
  final Uint8List secret;
  final DateTime expiresAt;

  /// `host:port` addresses to try, LAN first.
  final List<String> endpoints;

  static const _prefix = 'notes-pair:1:';

  /// Text for the QR code (and for pasting on devices without a camera).
  String encode() =>
      _prefix +
      base64Url.encode(
        utf8.encode(
          jsonEncode({
            'id': deviceId,
            'name': deviceName,
            'offer': base64Encode(offerId),
            'secret': base64Encode(secret),
            'exp': expiresAt.millisecondsSinceEpoch,
            'ep': endpoints,
          }),
        ),
      );

  /// Parses scanned or pasted text. Throws [FormatException] with a
  /// readable message when it is not a pairing code.
  static PairingCode decode(String text) {
    final t = text.trim();
    if (!t.startsWith(_prefix)) {
      throw const FormatException('This is not a pairing code from Notes.');
    }
    try {
      final j = jsonDecode(
        utf8.decode(base64Url.decode(t.substring(_prefix.length))),
      ) as Map<String, Object?>;
      final id = j['id'] as String;
      if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(id)) {
        throw const FormatException('bad id');
      }
      final offer = base64Decode(j['offer'] as String);
      final secret = base64Decode(j['secret'] as String);
      if (offer.length != 8 || secret.length != 32) {
        throw const FormatException('bad key sizes');
      }
      final ep = [for (final e in (j['ep'] as List)) e as String];
      if (ep.length > 12) throw const FormatException('too many addresses');
      return PairingCode(
        deviceId: id,
        deviceName: (j['name'] as String).trim(),
        offerId: Uint8List.fromList(offer),
        secret: Uint8List.fromList(secret),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(j['exp'] as int),
        endpoints: ep,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('This pairing code is damaged.');
    }
  }

  bool get expired => !expiresAt.isAfter(DateTime.now());
}

/// The device showing a QR code: creates the offer and consumes it once.
class PairingHost {
  PairingHost({
    Duration lifetime = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       offer = PairingOffer(
         id: randomBytes(8),
         secret: randomBytes(32),
         expiresAt: (now ?? DateTime.now)().add(lifetime),
       );

  final DateTime Function() _now;
  final PairingOffer offer;
  bool _used = false;
  int _attempts = 0;

  /// Failed attempts before the offer is withdrawn (a wrong secret cannot be
  /// guessed, but there is no reason to keep answering).
  static const maxAttempts = 5;

  bool get active =>
      !_used && _attempts < maxAttempts && offer.expiresAt.isAfter(_now());

  /// For [SecureChannel.respond]: the offer, if it is still usable.
  PairingOffer? lookup(Uint8List id) {
    if (!active) return null;
    if (id.length != offer.id.length) return null;
    var diff = 0;
    for (var i = 0; i < id.length; i++) {
      diff |= id[i] ^ offer.id[i];
    }
    if (diff != 0) return null;
    _attempts++;
    return offer;
  }

  /// Marks the offer as spent. Call as soon as a handshake with it succeeds.
  void consume() => _used = true;

  PairingCode code({
    required String deviceId,
    required String deviceName,
    required List<String> endpoints,
  }) => PairingCode(
    deviceId: deviceId,
    deviceName: deviceName,
    offerId: offer.id,
    secret: offer.secret,
    expiresAt: offer.expiresAt,
    endpoints: endpoints,
  );
}

class PairingFailure implements Exception {
  PairingFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Exchanges identities over an established pairing channel and stores the
/// other device on both sides. Neither side keeps the other unless both
/// accepted.
Future<Peer> completePairing({
  required SecureChannel channel,
  required PeerStore peers,
  required String myId,
  required String myName,
  required Uint8List myPublicKey,
  required List<String> myEndpoints,
  String? theirHost,
  List<String> knownEndpoints = const [],
  Duration timeout = const Duration(seconds: 20),
}) async {
  final ms = MessageStream(channel);
  try {
    await ms.send({
      't': 'peer',
      'id': myId,
      'name': myName,
      'pk': base64Encode(myPublicKey),
      'ep': myEndpoints,
    });
    final info = await ms.expect('peer').timeout(timeout);
    final id = info['id'];
    final name = info['name'];
    final pk = info['pk'];
    final advertised = info['ep'];
    if (id is! String ||
        name is! String ||
        pk is! String ||
        id != channel.peerId) {
      throw PairingFailure(
        'The other device identified itself inconsistently.',
      );
    }
    final key = base64Decode(pk);
    String? problem;
    if (key.length != 32) {
      problem = 'The other device sent an invalid key.';
    } else if (peers.list().length >= maxDevices - 1 && peers.get(id) == null) {
      problem = 'This device is already paired with the most devices allowed.';
    } else if (peers.get(id) != null && !_same(peers.get(id)!.publicKey, key)) {
      problem = 'This device was paired before with a different key. Remove the old entry first.';
    }
    await ms.send(
      problem == null ? {'t': 'accept'} : {'t': 'reject', 'reason': problem},
    );
    final verdict = await ms.receive().timeout(timeout);
    if (verdict['t'] == 'reject') {
      throw PairingFailure('The other device refused: ${verdict['reason']}');
    }
    if (verdict['t'] != 'accept') {
      throw PairingFailure('Unexpected reply while pairing.');
    }
    if (problem != null) throw PairingFailure(problem);
    // Where to reach them later: addresses they listed (each with their
    // listening port), the one we actually saw them on, and any we already
    // knew. Entries that are not plain host:port are ignored.
    final ports = <int>{};
    final listed = <String>[
      if (advertised is List)
        for (final e in advertised.take(12))
          if (e is String && _hostPort.hasMatch(e)) e,
    ];
    for (final e in listed) {
      ports.add(int.parse(e.substring(e.lastIndexOf(':') + 1)));
    }
    final seen = <String>[
      if (theirHost != null && ports.isNotEmpty) '$theirHost:${ports.first}',
    ];
    return peers.add(
      id: id,
      name: name.trim().isEmpty ? 'Device' : name.trim(),
      publicKey: Uint8List.fromList(key),
      endpoints: {...seen, ...knownEndpoints, ...listed}.take(6).toList(),
    );
  } on TimeoutException {
    throw PairingFailure('The other device stopped responding.');
  } finally {
    await channel.close();
  }
}

final _hostPort = RegExp(r'^[0-9a-zA-Z.\-]{1,100}:[0-9]{1,5}$');

bool _same(Uint8List a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}
