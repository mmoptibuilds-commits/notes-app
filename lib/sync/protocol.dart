import 'dart:convert';
import 'dart:typed_data';

import 'secure_channel.dart';

/// A peer sent something that is not valid protocol, or broke a limit.
class SyncProtocolException implements Exception {
  SyncProtocolException(this.message);
  final String message;
  @override
  String toString() => 'SyncProtocolException: $message';
}

/// Limits that protect this device from a buggy or hostile peer.
abstract final class SyncLimits {
  /// Largest single frame we emit as one piece (JSON text).
  static const directFrame = 700 * 1024;

  /// Raw bytes per fragment of an oversized message.
  static const fragmentBytes = 512 * 1024;

  /// Largest logical message after reassembly.
  static const maxMessage = 64 * 1024 * 1024;

  /// Rows accepted from a peer in one session.
  static const maxRows = 500000;

  /// Bytes of row data accepted from a peer in one session.
  static const maxSessionBytes = 512 * 1024 * 1024;

  /// Largest attachment accepted.
  static const maxAttachment = 64 * 1024 * 1024;

  /// Attachment bytes per blob message.
  static const blobChunk = 192 * 1024;

  /// Attachment bytes accepted from a peer in one session.
  static const maxAttachmentBytesPerSession = 512 * 1024 * 1024;

  /// Hashes requested in one `need` message.
  static const maxNeed = 500;
}

/// Sends and receives logical JSON messages over a [SecureChannel], splitting
/// oversized ones into fragments and reassembling them.
class MessageStream {
  MessageStream(this.channel);

  final SecureChannel channel;
  int bytesIn = 0;

  Future<void> send(Map<String, Object?> message) async {
    final bytes = utf8.encode(jsonEncode(message));
    if (bytes.length <= SyncLimits.directFrame) {
      await channel.send(Uint8List.fromList(bytes));
      return;
    }
    if (bytes.length > SyncLimits.maxMessage) {
      throw SyncProtocolException('message too large to send');
    }
    final n = (bytes.length / SyncLimits.fragmentBytes).ceil();
    for (var i = 0; i < n; i++) {
      final from = i * SyncLimits.fragmentBytes;
      final to = (from + SyncLimits.fragmentBytes).clamp(0, bytes.length);
      await channel.send(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              't': 'frag',
              'i': i,
              'n': n,
              'd': base64Encode(bytes.sublist(from, to)),
            }),
          ),
        ),
      );
    }
  }

  /// The next logical message.
  Future<Map<String, Object?>> receive() async {
    BytesBuilder? partial;
    var expected = 0;
    var total = 0;
    while (true) {
      final frame = await channel.receive();
      bytesIn += frame.length;
      final m = _decode(frame);
      if (m['t'] != 'frag') {
        if (partial != null) {
          throw SyncProtocolException('message interrupted by another');
        }
        return m;
      }
      final i = m['i'];
      final n = m['n'];
      final d = m['d'];
      if (i is! int || n is! int || d is! String || n < 2 || i != expected) {
        throw SyncProtocolException('bad fragment');
      }
      partial ??= BytesBuilder(copy: false);
      final chunk = base64Decode(d);
      total += chunk.length;
      if (total > SyncLimits.maxMessage) {
        throw SyncProtocolException('message too large');
      }
      partial.add(chunk);
      expected++;
      if (expected == n) return _decode(partial.toBytes());
    }
  }

  Future<Map<String, Object?>> expect(String type) async {
    final m = await receive();
    if (m['t'] != type) {
      throw SyncProtocolException('expected $type, got ${m['t']}');
    }
    return m;
  }

  static Map<String, Object?> _decode(Uint8List bytes) {
    final Object? v;
    try {
      v = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw SyncProtocolException('not valid JSON');
    }
    if (v is! Map || v['t'] is! String) {
      throw SyncProtocolException('not a protocol message');
    }
    return Map<String, Object?>.from(v);
  }
}
