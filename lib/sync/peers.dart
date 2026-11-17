import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sqlite3/sqlite3.dart' show Row;

import '../data/app_database.dart';

/// Most devices that may sync together, this one included.
const maxDevices = 5;

/// This device's long-term X25519 key pair. The private half lives only in
/// the encrypted database and is never sent anywhere.
class DeviceIdentity {
  DeviceIdentity._(this.keyPair, this.publicKey, this._privateKey);

  final SimpleKeyPair keyPair;
  final Uint8List publicKey;
  final Uint8List _privateKey;

  static const _metaKey = 'identity_private';

  static Future<DeviceIdentity> loadOrCreate(AppDatabase db) async {
    final stored = db.getMeta(_metaKey);
    final Uint8List priv;
    if (stored == null) {
      final kp = await X25519().newKeyPair();
      priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
      db.transaction(() => db.setMeta(_metaKey, base64Encode(priv)));
    } else {
      priv = base64Decode(stored);
    }
    return fromPrivate(priv);
  }

  static Future<DeviceIdentity> fromPrivate(Uint8List priv) async {
    final kp = await X25519().newKeyPairFromSeed(priv);
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return DeviceIdentity._(kp, pub, priv);
  }

  /// Raw private key bytes, for tests only.
  Uint8List get debugPrivateKey => _privateKey;
}

class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.publicKey,
    required this.addedAt,
    required this.endpoints,
    required this.lastSyncAt,
    required this.lastError,
    required this.sentCursor,
    required this.recvCursor,
  });

  final String id;
  final String name;
  final Uint8List publicKey;
  final int addedAt;

  /// Last known `host:port` addresses (LAN or Tailscale), most recent first.
  final List<String> endpoints;
  final int? lastSyncAt;
  final String? lastError;
  final int sentCursor;
  final int recvCursor;
}

class PairingLimitException implements Exception {
  @override
  String toString() =>
      'This device is already paired with ${maxDevices - 1} others, the most '
      'that can sync together. Remove one first.';
}

/// Paired devices and their sync cursors.
class PeerStore {
  PeerStore(this.db, {int Function()? nowMs})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase db;
  final int Function() _now;

  List<Peer> list() => [
    for (final r in db.select('SELECT * FROM peers ORDER BY added_at, id'))
      _peer(r),
  ];

  Peer? get(String id) {
    final rows = db.select('SELECT * FROM peers WHERE id = ?', [id]);
    return rows.isEmpty ? null : _peer(rows.first);
  }

  /// Adds a device, or refreshes the name and address of one already paired
  /// with the same key. A different key under a known id is refused: that is
  /// either a reinstall (remove the old entry first) or an impersonation.
  Peer add({
    required String id,
    required String name,
    required Uint8List publicKey,
    List<String> endpoints = const [],
  }) {
    if (publicKey.length != 32) {
      throw ArgumentError.value(
        publicKey.length,
        'publicKey',
        'must be 32 bytes',
      );
    }
    if (id == db.deviceId) {
      throw ArgumentError.value(id, 'id', 'is this device');
    }
    return db.transaction(() {
      final existing = get(id);
      if (existing != null) {
        if (!_same(existing.publicKey, publicKey)) {
          throw StateError(
            'Device $id is already paired with a different key. Remove it '
            'before pairing again.',
          );
        }
        db.execute('UPDATE peers SET name = ?, endpoints = ? WHERE id = ?', [
          name,
          jsonEncode(_merge(endpoints, existing.endpoints)),
          id,
        ]);
      } else {
        if (list().length >= maxDevices - 1) throw PairingLimitException();
        db.execute(
          'INSERT INTO peers(id, name, public_key, added_at, endpoints) '
          'VALUES (?, ?, ?, ?, ?)',
          [id, name, publicKey, _now(), jsonEncode(endpoints)],
        );
      }
      return get(id)!;
    });
  }

  /// Un-pairs a device. It can no longer connect; notes already exchanged
  /// stay on both sides.
  void remove(String id) =>
      db.transaction(() => db.execute('DELETE FROM peers WHERE id = ?', [id]));

  void rename(String id, String name) => db.transaction(
    () => db.execute('UPDATE peers SET name = ? WHERE id = ?', [name, id]),
  );

  /// Remembers an address the peer was reached on, most recent first.
  void noteEndpoint(String id, String endpoint) {
    final p = get(id);
    if (p == null) return;
    final next = _merge([endpoint], p.endpoints);
    if (next.join() == p.endpoints.join()) return;
    db.transaction(
      () => db.execute('UPDATE peers SET endpoints = ? WHERE id = ?', [
        jsonEncode(next),
        id,
      ]),
    );
  }

  void recordSuccess(String id) => db.transaction(
    () => db.execute(
      'UPDATE peers SET last_sync_at = ?, last_error = NULL WHERE id = ?',
      [_now(), id],
    ),
  );

  void recordError(String id, String message) => db.transaction(
    () => db.execute('UPDATE peers SET last_error = ? WHERE id = ?', [
      message,
      id,
    ]),
  );

  /// Raises the cursors; they never move backwards. Call inside the
  /// transaction that applied the data they describe.
  void advance(String id, {int? sent, int? received}) {
    if (sent != null) {
      db.execute(
        'UPDATE peers SET sent_cursor = max(sent_cursor, ?) WHERE id = ?',
        [sent, id],
      );
    }
    if (received != null) {
      db.execute(
        'UPDATE peers SET recv_cursor = max(recv_cursor, ?) WHERE id = ?',
        [received, id],
      );
    }
  }

  /// Sets (not raises) the cursor for what we have received from [id]. Used
  /// when the peer tells us it was restored from an older copy, so its
  /// numbering started over.
  void setReceived(String id, int value) =>
      db.execute('UPDATE peers SET recv_cursor = ? WHERE id = ?', [value, id]);

  /// Keeps a row from [id] that could not be applied, for inspection.
  void quarantine(String id, String kind, String reason, String raw) {
    db.execute(
      'INSERT INTO quarantine(peer_id, kind, received_at, reason, raw) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        id,
        kind,
        _now(),
        reason,
        raw.length > 2000000 ? raw.substring(0, 2000000) : raw,
      ],
    );
    // Bounded: oldest entries go first.
    db.execute(
      'DELETE FROM quarantine WHERE id NOT IN '
      '(SELECT id FROM quarantine ORDER BY id DESC LIMIT 500)',
    );
  }

  int quarantined() =>
      db.select('SELECT count(*) AS n FROM quarantine').first['n'] as int;

  /// Local changes this peer has not confirmed yet (rows above its cursor).
  int pendingFor(String id) {
    final p = get(id);
    if (p == null) return 0;
    final r = db.select(
      'SELECT (SELECT count(*) FROM notes WHERE local_seq > ?) + '
      '(SELECT count(*) FROM folders WHERE local_seq > ?) AS n',
      [p.sentCursor, p.sentCursor],
    );
    return r.first['n'] as int;
  }

  static List<String> _merge(List<String> fresh, List<String> old) {
    final out = <String>[];
    for (final e in [...fresh, ...old]) {
      if (!out.contains(e)) out.add(e);
    }
    return out.take(6).toList();
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Peer _peer(Row r) => Peer(
    id: r['id'] as String,
    name: r['name'] as String,
    publicKey: Uint8List.fromList(r['public_key'] as List<int>),
    addedAt: r['added_at'] as int,
    endpoints: (jsonDecode(r['endpoints'] as String) as List).cast<String>(),
    lastSyncAt: r['last_sync_at'] as int?,
    lastError: r['last_error'] as String?,
    sentCursor: r['sent_cursor'] as int,
    recvCursor: r['recv_cursor'] as int,
  );
}
