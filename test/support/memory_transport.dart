import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:notes/sync/secure_channel.dart';

/// One end of an in-memory connection for tests. Whatever one end sends the
/// other receives, in order. [filter] sees every frame this end sends and
/// returns what actually gets delivered: nothing (drop), the frame
/// (normal), a changed copy (tamper), or several (duplicate/replay).
class MemoryEnd implements FrameTransport {
  MemoryEnd._();

  late MemoryEnd _peer;
  final _inbox = Queue<Uint8List>();
  Completer<void>? _waiting;
  bool _closed = false;

  /// Every frame this end was asked to send, before filtering.
  final sent = <Uint8List>[];
  Iterable<Uint8List> Function(Uint8List frame, int index)? filter;

  /// Close the connection after this many frames have been sent (a cable
  /// pulled mid-exchange). Null: never.
  int? cutAfterSending;

  static (MemoryEnd, MemoryEnd) pair() {
    final a = MemoryEnd._();
    final b = MemoryEnd._();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  void _deliver(Uint8List frame) {
    _inbox.add(frame);
    _waiting?.complete();
    _waiting = null;
  }

  /// Delivers [frame] to the other end without going through [filter].
  void inject(Uint8List frame) => _peer._deliver(frame);

  @override
  Future<void> send(Uint8List frame) async {
    if (_closed || _peer._closed) throw TransportClosed();
    final index = sent.length;
    sent.add(Uint8List.fromList(frame));
    if (cutAfterSending != null && index >= cutAfterSending!) {
      await close();
      throw TransportClosed('cut');
    }
    final out = filter == null ? [frame] : filter!(frame, index);
    for (final f in out) {
      _peer._deliver(Uint8List.fromList(f));
    }
  }

  @override
  Future<Uint8List> receive() async {
    while (true) {
      if (_inbox.isNotEmpty) return _inbox.removeFirst();
      if (_closed || _peer._closed) throw TransportClosed();
      _waiting = Completer<void>();
      await _waiting!.future;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _peer._waiting?.complete();
    _peer._waiting = null;
    _waiting?.complete();
    _waiting = null;
  }
}
