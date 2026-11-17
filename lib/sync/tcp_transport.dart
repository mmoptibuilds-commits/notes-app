import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'secure_channel.dart';

/// [FrameTransport] over a TCP socket: each frame is a 4-byte big-endian
/// length followed by that many bytes. The length is checked before any
/// allocation so a peer cannot make us reserve unbounded memory.
class TcpTransport implements FrameTransport {
  TcpTransport(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _sub = _socket.listen(
      _onData,
      onError: (Object e) => _fail('socket error'),
      onDone: () => _fail('connection closed'),
      cancelOnError: true,
    );
  }

  /// Largest frame accepted: one maximum message plus authentication tag and
  /// some slack for handshake frames.
  static const maxFrame = maxMessageBytes + 1024;

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buffer = BytesBuilder(copy: false);
  int _buffered = 0;
  int? _want;
  final _frames = Queue<Uint8List>();
  int _queuedBytes = 0;

  /// When this much received data is waiting to be read, stop reading from
  /// the socket (TCP then slows the sender) until the reader catches up. A
  /// peer that sends faster than we process cannot make us hold unbounded
  /// memory. The hard limit only guards against a bug.
  static const pauseAtBytes = 2 * maxFrame;
  static const resumeAtBytes = maxFrame;
  static const hardLimitBytes = 16 * maxFrame;
  bool _paused = false;
  Completer<void>? _waiter;
  String? _closedReason;

  /// The other end's address, `host:port`.
  String get remote => '${_socket.remoteAddress.address}:${_socket.remotePort}';
  InternetAddress get remoteAddress => _socket.remoteAddress;

  static Future<TcpTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    return TcpTransport(s);
  }

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    _buffered += chunk.length;
    _drain();
  }

  void _drain() {
    while (true) {
      if (_want == null) {
        if (_buffered < 4) return;
        final all = _buffer.takeBytes();
        _buffered = 0;
        final len = ByteData.sublistView(all).getUint32(0, Endian.big);
        if (len > maxFrame) {
          _fail('frame too large');
          return;
        }
        _want = len;
        if (all.length > 4) {
          _buffer.add(Uint8List.sublistView(all, 4));
          _buffered = all.length - 4;
        }
      }
      if (_buffered < _want!) return;
      final all = _buffer.takeBytes();
      _frames.add(Uint8List.sublistView(all, 0, _want!));
      _queuedBytes += _want!;
      if (_queuedBytes > hardLimitBytes) {
        _fail('too much unread data');
        return;
      }
      if (_queuedBytes >= pauseAtBytes && !_paused) {
        _paused = true;
        _sub.pause();
      }
      final rest = all.length - _want!;
      _buffered = rest;
      if (rest > 0) _buffer.add(Uint8List.sublistView(all, _want!));
      _want = null;
      _waiter?.complete();
      _waiter = null;
    }
  }

  void _fail(String reason) {
    _closedReason ??= reason;
    _sub.cancel();
    _socket.destroy();
    _waiter?.complete();
    _waiter = null;
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (_closedReason != null) throw TransportClosed(_closedReason!);
    if (frame.length > maxFrame) throw ArgumentError('frame too large');
    final header = Uint8List(4);
    ByteData.sublistView(header).setUint32(0, frame.length, Endian.big);
    try {
      _socket.add(header);
      _socket.add(frame);
      await _socket.flush();
    } on Object {
      _fail('write failed');
      throw TransportClosed(_closedReason!);
    }
  }

  @override
  Future<Uint8List> receive() async {
    while (true) {
      if (_frames.isNotEmpty) {
        final f = _frames.removeFirst();
        _queuedBytes -= f.length;
        if (_paused && _queuedBytes < resumeAtBytes) {
          _paused = false;
          _sub.resume();
        }
        return f;
      }
      if (_closedReason != null) throw TransportClosed(_closedReason!);
      _waiter = Completer<void>();
      await _waiter!.future;
    }
  }

  @override
  Future<void> close() async {
    _closedReason ??= 'closed locally';
    await _sub.cancel();
    _socket.destroy();
    _waiter?.complete();
    _waiter = null;
  }
}
