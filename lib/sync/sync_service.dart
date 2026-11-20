import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/note_repository.dart';
import 'pairing.dart';
import 'peers.dart';
import 'protocol.dart';
import 'secure_channel.dart';
import 'sync_session.dart';
import 'tcp_transport.dart';

/// Default TCP port for sync connections and UDP port for finding a paired
/// device whose address changed.
const defaultSyncPort = 47380;
const discoveryPort = 47381;

/// Runs this device's side of syncing: accepts connections from paired
/// devices, dials them when asked, pairs new devices, and keeps a short
/// plain-language status for the UI.
///
/// It does no work on a timer. Syncs start when the app opens or resumes,
/// after local edits settle, or when the user asks.
class SyncService extends ChangeNotifier {
  SyncService({
    required this.repo,
    required this.peers,
    required this.identity,
    required this.deviceName,
    this.port = defaultSyncPort,
    this.bindAddress,
    this.enableDiscovery = true,
    this.handshakeTimeout = const Duration(seconds: 6),
    Future<List<String>> Function()? localAddresses,
  }) : _localAddresses = localAddresses ?? _interfaceAddresses;

  final NoteRepository repo;
  final PeerStore peers;
  final DeviceIdentity identity;

  /// Name shown to other devices. Can be changed at any time.
  String deviceName;
  int port;
  final InternetAddress? bindAddress;
  final bool enableDiscovery;

  /// How long a new connection may take to prove who it is.
  final Duration handshakeTimeout;
  final Future<List<String>> Function() _localAddresses;

  ServerSocket? _server;
  RawDatagramSocket? _udp;
  PairingHost? _pairing;
  final _paired = StreamController<Peer>.broadcast();
  final _busy = <String>{};
  final _sessionCompletions = <String, Completer<SyncOutcome?>>{};
  final _outgoingDials = <String, _OutgoingDial>{};
  final _activeChannels = <String, Set<SecureChannel>>{};
  final _nextAttempt = <String, DateTime>{};
  final _failures = <String, int>{};
  Timer? _debounce;
  bool _stopped = true;

  /// Peers added by an incoming pairing (the other device scanned our code).
  Stream<Peer> get onPaired => _paired.stream;

  bool get running => !_stopped;
  bool get syncing =>
      _busy.isNotEmpty ||
      _outgoingDials.isNotEmpty ||
      _sessionCompletions.isNotEmpty ||
      _manualRun;
  bool _manualRun = false;
  String? currentPeerName;

  /// Latest result per peer id: null means the last attempt succeeded.
  final lastError = <String, String>{};

  /// What the most recent session with each peer did.
  final lastOutcome = <String, SyncOutcome>{};

  /// This device's reachable addresses (LAN, Tailscale), for display.
  Future<List<String>> addresses() async => [
    for (final a in await _localAddresses()) '$a:$port',
  ];

  PairingHost? get pairing => _pairing?.active == true ? _pairing : null;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  // ---------------------------------------------------------------- server

  Future<void> start() async {
    if (!_stopped) return;
    _stopped = false;
    final addr = bindAddress ?? InternetAddress.anyIPv4;
    try {
      _server = await ServerSocket.bind(addr, port);
    } on SocketException {
      _server = await ServerSocket.bind(addr, 0);
    }
    port = _server!.port;
    _server!.listen(_accept, onError: (Object _) {});
    if (enableDiscovery) await _startDiscovery();
    notifyListeners();
  }

  Future<void> stop() async {
    await _teardown();
    if (!_disposed) notifyListeners();
  }

  Future<void> _teardown() async {
    _stopped = true;
    _debounce?.cancel();
    for (final channels in _activeChannels.values) {
      for (final channel in channels.toList()) {
        unawaited(channel.close());
      }
    }
    for (final id in _sessionCompletions.keys.toList()) {
      _completeSession(id, null);
    }
    final server = _server;
    _server = null;
    _udp?.close();
    _udp = null;
    await server?.close();
  }

  void _trackChannel(String peerId, SecureChannel channel) {
    _activeChannels.putIfAbsent(peerId, () => <SecureChannel>{}).add(channel);
  }

  void _untrackChannel(String peerId, SecureChannel channel) {
    final channels = _activeChannels[peerId];
    channels?.remove(channel);
    if (channels != null && channels.isEmpty) _activeChannels.remove(peerId);
  }

  void _completeSession(String peerId, SyncOutcome? outcome) {
    final completion = _sessionCompletions.remove(peerId);
    if (completion != null && !completion.isCompleted) {
      completion.complete(outcome);
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    _paired.close();
    super.dispose();
  }

  /// Connections that have not yet proved who they are, in total and per
  /// address, and established sessions. Strangers on the network cannot use
  /// up the slots that paired devices need.
  int _handshaking = 0;
  int _sessions = 0;
  final _perAddress = <String, int>{};
  static const _maxHandshakes = 6;
  static const _maxHandshakesPerAddress = 2;
  static const _maxSessions = 3;

  void _accept(Socket socket) {
    final ip = socket.remoteAddress.address;
    if (_stopped ||
        _handshaking >= _maxHandshakes ||
        (_perAddress[ip] ?? 0) >= _maxHandshakesPerAddress) {
      socket.destroy();
      return;
    }
    _handshaking++;
    _perAddress[ip] = (_perAddress[ip] ?? 0) + 1;
    unawaited(
      _handle(TcpTransport(socket), ip).whenComplete(() {
        final n = (_perAddress[ip] ?? 1) - 1;
        if (n <= 0) {
          _perAddress.remove(ip);
        } else {
          _perAddress[ip] = n;
        }
      }),
    );
  }

  Future<void> _handle(TcpTransport t, String ip) async {
    String? peerId;
    _IncomingSession? incomingSession;
    var incomingAccepted = false;
    SyncOutcome? incomingOutcome;
    var handshaking = true;
    void established() {
      if (!handshaking) return;
      handshaking = false;
      _handshaking--;
      _sessions++;
    }

    try {
      final ch = await SecureChannel.respond(
        t,
        myId: repo.db.deviceId,
        identity: identity,
        lookupPeer: peers.get,
        lookupOffer: (id) => _pairing?.lookup(id),
        onSessionPeer: (id) {
          final outgoing = _outgoingDials[id];
          if (outgoing != null && !shouldDial(repo.db.deviceId, id)) {
            incomingSession = outgoing.noteIncoming();
          }
        },
        rejectSessionPeer: (id) async {
          final outgoing = _outgoingDials[id];
          if (outgoing == null || !shouldDial(repo.db.deviceId, id)) {
            return false;
          }
          return outgoing.handshake.future;
        },
      ).timeout(handshakeTimeout);
      established();
      peerId = ch.peerId;
      final outgoing = ch.mode == HandshakeMode.session
          ? _outgoingDials[ch.peerId]
          : null;
      if (outgoing != null) {
        if (shouldDial(repo.db.deviceId, ch.peerId) &&
            await outgoing.handshake.future) {
          await ch.close();
          return;
        }
        incomingSession ??= outgoing.noteIncoming();
      }
      if (_sessions > _maxSessions) {
        await ch.close();
        return;
      }
      if (ch.mode == HandshakeMode.pairing) {
        final host = _pairing;
        if (host == null || !host.consume()) {
          await ch.close();
          return;
        }
        final addrs = await _localAddresses();
        final peer = await completePairing(
          channel: ch,
          peers: peers,
          myId: repo.db.deviceId,
          myName: deviceName,
          myPublicKey: identity.publicKey,
          myEndpoints: [for (final a in addrs) '$a:$port'],
          theirHost: t.remoteAddress.address,
        );
        _pairing = null;
        _paired.add(peer);
        notifyListeners();
        return;
      }
      if (peers.get(ch.peerId) == null) {
        await ch.close();
        return;
      }
      _trackChannel(ch.peerId, ch);
      try {
        incomingOutcome = await _runSession(
          ch,
          onStarted: () => incomingAccepted = true,
        );
      } finally {
        _untrackChannel(ch.peerId, ch);
      }
    } on Object catch (e) {
      if (e is! _SessionAlreadyRunning &&
          peerId != null &&
          peers.get(peerId) != null) {
        final message = describeSyncError(e);
        lastError[peerId] = message;
        peers.recordError(peerId, message);
        notifyListeners();
      }
      await t.close();
    } finally {
      incomingSession?.complete(incomingAccepted, incomingOutcome);
      if (handshaking) {
        _handshaking--;
      } else {
        _sessions--;
      }
    }
  }

  Future<SyncOutcome> _runSession(
    SecureChannel channel, {
    void Function()? onStarted,
  }) async {
    final id = channel.peerId;
    if (peers.get(id) == null) {
      await channel.close();
      throw SyncProtocolException('not a paired device');
    }
    if (!_busy.add(id)) {
      await channel.close();
      throw _SessionAlreadyRunning();
    }
    final completion = Completer<SyncOutcome?>();
    _sessionCompletions[id] = completion;
    SyncOutcome? outcome;
    try {
      currentPeerName = peers.get(id)?.name;
      onStarted?.call();
      notifyListeners();
      outcome = await SyncSession(
        channel: channel,
        repo: repo,
        peers: peers,
        deviceName: deviceName,
      ).run();
      lastOutcome[id] = outcome;
      lastError.remove(id);
      _failures.remove(id);
      _nextAttempt.remove(id);
      return outcome;
    } finally {
      if (!completion.isCompleted) completion.complete(outcome);
      if (identical(_sessionCompletions[id], completion)) {
        _sessionCompletions.remove(id);
      }
      _busy.remove(id);
      if (_busy.isEmpty && _outgoingDials.isEmpty && !_manualRun) {
        currentPeerName = null;
      }
      notifyListeners();
    }
  }

  // --------------------------------------------------------------- pairing

  /// Starts showing a pairing code. The code is valid for five minutes and
  /// works once.
  Future<PairingCode> beginPairing() async {
    if (_stopped) await start();
    final host = PairingHost();
    _pairing = host;
    final addrs = await _localAddresses();
    notifyListeners();
    return host.code(
      deviceId: repo.db.deviceId,
      deviceName: deviceName,
      endpoints: [for (final a in addrs) '$a:$port'],
    );
  }

  void cancelPairing() {
    _pairing = null;
    notifyListeners();
  }

  /// Pairs with the device that showed [code]. Throws [PairingFailure] or
  /// [FormatException] with a message fit for the user.
  Future<Peer> pairWith(PairingCode code) async {
    if (code.expired) throw PairingFailure('This pairing code has expired.');
    if (code.deviceId == repo.db.deviceId) {
      throw PairingFailure('That code is from this device.');
    }
    Object? last;
    for (final ep in code.endpoints) {
      final hp = _parse(ep);
      if (hp == null) continue;
      TcpTransport? t;
      try {
        t = await TcpTransport.connect(hp.$1, hp.$2);
        final ch = await SecureChannel.initiatePairing(
          t,
          myId: repo.db.deviceId,
          peerId: code.deviceId,
          offerId: code.offerId,
          offerSecret: code.secret,
        ).timeout(const Duration(seconds: 10));
        final addrs = await _localAddresses();
        return await completePairing(
          channel: ch,
          peers: peers,
          myId: repo.db.deviceId,
          myName: deviceName,
          myPublicKey: identity.publicKey,
          myEndpoints: [for (final a in addrs) '$a:$port'],
          knownEndpoints: [
            ep,
            for (final e in code.endpoints)
              if (e != ep) e,
          ],
        );
      } on SocketException catch (e) {
        last = e;
      } on TimeoutException catch (e) {
        last = e;
      } on HandshakeException catch (e) {
        await t?.close();
        throw PairingFailure(e.message);
      } on TransportClosed catch (e) {
        last = e;
      }
      await t?.close();
    }
    throw PairingFailure(
      'Could not reach the other device. Make sure both are on the same '
      'network (or both on Tailscale) and the code is still showing.'
      '${last == null ? '' : ' ($last)'}',
    );
  }

  // ------------------------------------------------------------------ sync

  /// Renames a paired device (a label only this device sees).
  void renamePeer(String id, String name) {
    peers.rename(id, name);
    notifyListeners();
  }

  /// Un-pairs a device and updates the status shown.
  void removePeer(String id) {
    peers.remove(id);
    lastError.remove(id);
    lastOutcome.remove(id);
    _failures.remove(id);
    _nextAttempt.remove(id);
    _completeSession(id, null);
    final channels = _activeChannels.remove(id);
    if (channels != null) {
      for (final channel in channels) {
        unawaited(channel.close());
      }
    }
    notifyListeners();
  }

  /// Syncs with every paired device now. Returns the outcomes by peer id
  /// (only for devices that were reached).
  Future<Map<String, SyncOutcome>> syncAll() async {
    if (_stopped) await start();
    final out = <String, SyncOutcome>{};
    _manualRun = true;
    notifyListeners();
    try {
      for (final p in peers.list()) {
        final o = await syncPeer(p.id);
        if (o != null) out[p.id] = o;
      }
    } finally {
      _manualRun = false;
      currentPeerName = null;
      notifyListeners();
    }
    return out;
  }

  /// Syncs with one device. Either device may dial; simultaneous dials are
  /// resolved by the lower device id. Returns null when a dial or session
  /// fails (see [lastError]).
  Future<SyncOutcome?> syncPeer(String id) async {
    final peer = peers.get(id);
    if (peer == null) return null;
    final runningSession = _sessionCompletions[id];
    if (runningSession != null) return runningSession.future;
    final existingDial = _outgoingDials[id];
    if (existingDial != null) return existingDial.completion.future;

    final attempt = _OutgoingDial();
    _outgoingDials[id] = attempt;
    currentPeerName = peer.name;
    notifyListeners();
    SyncOutcome? outcome;
    try {
      try {
        outcome = await _dial(peer, attempt);
        lastOutcome[id] = outcome;
        lastError.remove(id);
        _failures.remove(id);
        _nextAttempt.remove(id);
      } on Object catch (e) {
        if (!attempt.handshake.isCompleted) attempt.handshake.complete(false);
        final incoming = attempt.incoming;
        if (incoming != null) {
          final result = await incoming.result.future;
          if (result.accepted) {
            outcome = result.outcome;
            return outcome;
          }
        }
        if (peers.get(id) != null) {
          final msg = e is _Unreachable ? e.message : describeSyncError(e);
          lastError[id] = msg;
          peers.recordError(id, msg);
          final n = (_failures[id] ?? 0) + 1;
          _failures[id] = n;
          _nextAttempt[id] = DateTime.now().add(
            Duration(seconds: [20, 60, 180, 600, 900][n.clamp(1, 5) - 1]),
          );
        }
        return null;
      }
      return outcome;
    } finally {
      if (identical(_outgoingDials[id], attempt)) {
        _outgoingDials.remove(id);
      }
      if (!attempt.completion.isCompleted) attempt.completion.complete(outcome);
      if (_busy.isEmpty && _outgoingDials.isEmpty && !_manualRun) {
        currentPeerName = null;
      }
      notifyListeners();
    }
  }

  /// Called when the app opens or resumes, and shortly after local edits:
  /// syncs with devices that are due, without nagging unreachable ones.
  void requestAutoSync({Duration after = Duration.zero}) {
    if (_stopped || peers.list().isEmpty) return;
    _debounce?.cancel();
    _debounce = Timer(after, () async {
      for (final p in peers.list()) {
        final next = _nextAttempt[p.id];
        if (next != null && next.isAfter(DateTime.now())) continue;
        if (_busy.contains(p.id)) continue;
        await syncPeer(p.id);
      }
    });
  }

  Future<SyncOutcome> _dial(Peer peer, _OutgoingDial outgoing) async {
    final tried = <String>{};
    Future<SyncOutcome?> attempt(String ep) async {
      if (!tried.add(ep)) return null;
      final hp = _parse(ep);
      if (hp == null) return null;
      TcpTransport t;
      try {
        t = await TcpTransport.connect(
          hp.$1,
          hp.$2,
          timeout: const Duration(seconds: 3),
        );
      } on Object {
        return null;
      }
      final SecureChannel ch;
      try {
        ch = await SecureChannel.initiateSession(
          t,
          myId: repo.db.deviceId,
          identity: identity,
          peerId: peer.id,
          peerPublicKey: peer.publicKey,
        ).timeout(const Duration(seconds: 10));
        if (!outgoing.handshake.isCompleted) outgoing.handshake.complete(true);
      } on Object {
        if (!outgoing.handshake.isCompleted) outgoing.handshake.complete(false);
        rethrow;
      }
      _trackChannel(peer.id, ch);
      try {
        if (peers.get(peer.id) == null) {
          await ch.close();
          throw SyncProtocolException('not a paired device');
        }
        final outcome = await _runSession(ch);
        peers.noteEndpoint(peer.id, ep);
        return outcome;
      } finally {
        _untrackChannel(peer.id, ch);
      }
    }

    for (final ep in peer.endpoints) {
      final o = await attempt(ep);
      if (o != null) return o;
    }
    if (enableDiscovery) {
      for (final ep in await _discover(peer.id)) {
        final o = await attempt(ep);
        if (o != null) return o;
      }
    }
    if (!outgoing.handshake.isCompleted) outgoing.handshake.complete(false);
    throw _Unreachable(
      '${peer.name} is not reachable right now. Open Notes on both devices '
      'on the same network or Tailscale.',
    );
  }

  // ------------------------------------------------------------- discovery

  /// What a discovery packet carries instead of a device id. It changes every
  /// day, so someone watching the network cannot follow one device by it.
  static List<int> _tag(String deviceId, int day) => sha256
      .convert(utf8.encode('notes-discovery-v2$deviceId:$day'))
      .bytes
      .sublist(0, 8);

  static int get _today =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;

  Future<void> _startDiscovery() async {
    try {
      final s = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _udp = s;
      final id = repo.db.deviceId;
      s.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null || d.data.length != 5 + 8) return;
        if (utf8.decode(d.data.sublist(0, 5), allowMalformed: true) !=
            'NTSD1') {
          return;
        }
        // Accept yesterday's and tomorrow's too: clocks and midnight differ.
        final asked = d.data.sublist(5);
        final day = _today;
        final mine = [
          for (final dd in [day, day - 1, day + 1])
            if (_eq(asked, _tag(id, dd))) asked,
        ];
        if (mine.isEmpty) return;
        final reply = BytesBuilder()
          ..add(utf8.encode('NTSR1'))
          ..add(mine.first)
          ..add([port >> 8, port & 0xff]);
        s.send(reply.toBytes(), d.address, d.port);
      });
    } on SocketException {
      // Port in use (another instance): discovery of *us* is unavailable,
      // everything else still works.
    }
  }

  Future<List<String>> _discover(String peerId) async {
    final tag = _tag(peerId, _today);
    final found = <String>[];
    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.broadcastEnabled = true;
      final done = Completer<void>();
      s.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = s!.receive();
        if (d == null || d.data.length != 5 + 8 + 2) return;
        if (utf8.decode(d.data.sublist(0, 5), allowMalformed: true) !=
            'NTSR1') {
          return;
        }
        if (!_eq(d.data.sublist(5, 13), tag)) return;
        final p = (d.data[13] << 8) | d.data[14];
        found.add('${d.address.address}:$p');
        if (!done.isCompleted) done.complete();
      });
      final req = Uint8List.fromList([...utf8.encode('NTSD1'), ...tag]);
      final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
      for (final a in await _localAddresses()) {
        final o = a.split('.');
        if (o.length == 4) {
          targets.add(InternetAddress('${o[0]}.${o[1]}.${o[2]}.255'));
        }
      }
      for (final t in targets) {
        try {
          s.send(req, t, discoveryPort);
        } on Object {
          // some interfaces refuse broadcast; others will do
        }
      }
      await done.future.timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () {},
      );
    } on Object {
      // discovery is best effort
    } finally {
      s?.close();
    }
    return found;
  }

  // --------------------------------------------------------------- helpers

  static (String, int)? _parse(String ep) {
    final i = ep.lastIndexOf(':');
    if (i <= 0) return null;
    final port = int.tryParse(ep.substring(i + 1));
    if (port == null || port < 1 || port > 65535) return null;
    return (ep.substring(0, i), port);
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  /// Non-loopback IPv4 addresses of this device (LAN, Tailscale, ...).
  static Future<List<String>> _interfaceAddresses() async {
    final out = <String>[];
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        if (a.isLoopback || a.isLinkLocal) continue;
        out.add(a.address);
      }
    }
    return out;
  }
}

class _OutgoingDial {
  final completion = Completer<SyncOutcome?>();
  final handshake = Completer<bool>();
  _IncomingSession? incoming;

  _IncomingSession noteIncoming() => incoming ??= _IncomingSession();
}

class _IncomingSession {
  final result = Completer<_IncomingSessionResult>();

  void complete(bool accepted, SyncOutcome? outcome) {
    if (!result.isCompleted) {
      result.complete(_IncomingSessionResult(accepted, outcome));
    }
  }
}

class _IncomingSessionResult {
  const _IncomingSessionResult(this.accepted, this.outcome);

  final bool accepted;
  final SyncOutcome? outcome;
}

class _SessionAlreadyRunning implements Exception {}

class _Unreachable implements Exception {
  _Unreachable(this.message);
  final String message;
}

/// Short label for an address: Tailscale addresses live in 100.64.0.0/10.
String describeEndpoint(String endpoint) {
  final host = endpoint.split(':').first;
  final o = host.split('.').map(int.tryParse).toList();
  if (o.length == 4 &&
      o[0] == 100 &&
      o[1] != null &&
      o[1]! >= 64 &&
      o[1]! <= 127) {
    return 'Tailscale $host';
  }
  return host;
}
