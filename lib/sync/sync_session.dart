import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../data/migrations.dart';
import '../data/models.dart';
import '../data/note_repository.dart';
import '../doc/delta_text.dart';
import 'merge.dart';
import 'peers.dart';
import 'protocol.dart';
import 'secure_channel.dart';

/// What one sync session did.
class SyncOutcome {
  int sentRows = 0;
  int receivedRows = 0;
  int created = 0;
  int updated = 0;
  int unchanged = 0;
  int conflictCopies = 0;

  /// Rows the peer sent that could not be understood; skipped, not applied.
  int invalidRows = 0;
  int attachmentsReceived = 0;
  int attachmentsSent = 0;

  /// Images referenced by notes that the peer did not have either.
  int attachmentsStillMissing = 0;

  bool get changedLocalData => created + updated > 0;

  @override
  String toString() =>
      'sent $sentRows, received $receivedRows (new $created, updated $updated, '
      'same $unchanged, conflicts $conflictCopies, invalid $invalidRows), '
      'images in $attachmentsReceived / out $attachmentsSent';
}

class SyncTimeoutException implements Exception {
  @override
  String toString() => 'The other device stopped responding.';
}

/// One synchronisation with one paired device over an established
/// [SecureChannel]. Both sides run the same code.
///
/// Order of events (each side sends the same sequence):
///  1. `hello`: who I am and the highest of your changes I already have.
///  2. my changes you lack (`rows`...), then `done`.
///  3. When your `done` arrives, everything you sent is applied in ONE
///     transaction (so a conflict copy and the note that resolved it are
///     never separated), with my cursor for you advanced in the same
///     transaction. Then `applied`.
///  4. `need`: images my notes refer to that I do not have; `blob`s answer
///     the peer's `need`; `bye`.
/// Nothing is committed from a session that fails before step 3 completes,
/// and re-running a session is harmless.
class SyncSession {
  SyncSession({
    required this.channel,
    required this.repo,
    required this.peers,
    required this.deviceName,
    this.idleTimeout = const Duration(seconds: 45),
    this.sessionDeadline = const Duration(minutes: 30),
    int Function()? nowMs,
  }) : _applier = RemoteApplier(repo, nowMs: nowMs),
       _ms = MessageStream(channel);

  final SecureChannel channel;
  final NoteRepository repo;
  final PeerStore peers;
  final String deviceName;
  final Duration idleTimeout;

  /// Longest a whole session may take, however busy the connection looks.
  final Duration sessionDeadline;
  final RemoteApplier _applier;
  final MessageStream _ms;
  final outcome = SyncOutcome();

  Future<Map<String, Object?>> _recv([String? type]) async {
    try {
      final m = await (type == null ? _ms.receive() : _ms.expect(type)).timeout(
        idleTimeout,
      );
      return m;
    } on TimeoutException {
      await channel.close();
      throw SyncTimeoutException();
    }
  }

  Future<SyncOutcome> run() async {
    final peer = peers.get(channel.peerId);
    if (peer == null) throw SyncProtocolException('not a paired device');
    try {
      try {
        await _exchange(peer).timeout(sessionDeadline);
      } on TimeoutException {
        await channel.close();
        throw SyncTimeoutException();
      }
      peers.recordSuccess(peer.id);
      return outcome;
    } finally {
      await channel.close();
    }
  }

  Future<void> _exchange(Peer peer) async {
    final db = repo.db;
    await _ms.send({
      't': 'hello',
      'proto': 1,
      'id': db.deviceId,
      'name': deviceName,
      'schema': schemaVersion,
      'from': peer.recvCursor,
      'max': db.currentSeq,
    });
    final hello = await _recv('hello');
    if (hello['id'] != peer.id) {
      throw SyncProtocolException('hello from a different device');
    }
    final theirFrom = _int(hello['from']);
    final snapshot = db.currentSeq;
    // A cursor ahead of everything we have means we were restored from an
    // older copy: send it all rather than silently skipping new changes.
    final reset = theirFrom > snapshot;
    final from = reset ? 0 : theirFrom;

    // --- data, both directions at once so neither side can stall the other
    // If the connection drops while we are still reading, this send fails too;
    // `ignore` keeps that second failure from being reported as unhandled.
    final sending = _sendRows(from, snapshot, reset)..ignore();
    final received = await _receiveRows();
    await sending;
    _applyReceived(peer.id, received);
    await _ms.send({'t': 'applied', 'upTo': received.upTo});
    final ack = await _recv('applied');
    final upTo = _int(ack['upTo']);
    db.transaction(
      () => peers.advance(peer.id, sent: upTo > snapshot ? snapshot : upTo),
    );

    // --- images
    await _exchangeAttachments();
    await _ms.send({'t': 'bye'});
    await _recv('bye');
  }

  // ----------------------------------------------------------------- rows

  Future<void> _sendRows(int from, int upTo, bool reset) async {
    final folders = [
      for (final (seq, f) in repo.folderRecordsSince(from))
        if (seq <= upTo) f.toJson(),
    ];
    if (folders.isNotEmpty) {
      outcome.sentRows += folders.length;
      await _ms.send({'t': 'rows', 'k': 'folders', 'rows': folders});
    }
    var cursor = from;
    while (true) {
      final page = repo.noteRecordsSince(cursor, limit: 200);
      if (page.isEmpty) break;
      var batch = <Map<String, Object?>>[];
      var size = 0;
      var done = false;
      for (final (seq, r) in page) {
        cursor = seq;
        if (seq > upTo) {
          done = true;
          break;
        }
        final json = r.toJson();
        batch.add(json);
        size += (r.body.length + r.title.length) + 600;
        if (size >= 400 * 1024) {
          outcome.sentRows += batch.length;
          await _ms.send({'t': 'rows', 'k': 'notes', 'rows': batch});
          batch = [];
          size = 0;
        }
      }
      if (batch.isNotEmpty) {
        outcome.sentRows += batch.length;
        await _ms.send({'t': 'rows', 'k': 'notes', 'rows': batch});
      }
      if (done || page.length < 200) break;
    }
    await _ms.send({
      't': 'done',
      'upTo': upTo,
      'count': outcome.sentRows,
      'reset': reset,
    });
  }

  Future<_Received> _receiveRows() async {
    final r = _Received();
    while (true) {
      final m = await _recv();
      switch (m['t']) {
        case 'rows':
          final rows = m['rows'];
          if (rows is! List) throw SyncProtocolException('rows is not a list');
          r.count += rows.length;
          if (r.count > SyncLimits.maxRows ||
              _ms.bytesIn > SyncLimits.maxSessionBytes) {
            throw SyncProtocolException('peer sent too much in one session');
          }
          final target = switch (m['k']) {
            'folders' => r.folders,
            'notes' => r.notes,
            _ => throw SyncProtocolException('unknown row kind'),
          };
          for (final row in rows) {
            if (row is! Map) {
              throw SyncProtocolException('row is not an object');
            }
            target.add(Map<String, Object?>.from(row));
          }
        case 'done':
          r.upTo = _int(m['upTo']);
          r.reset = m['reset'] == true;
          if (_int(m['count']) != r.count) {
            throw SyncProtocolException('row count does not match');
          }
          return r;
        default:
          throw SyncProtocolException('unexpected ${m['t']} while receiving');
      }
    }
  }

  void _applyReceived(String peerId, _Received r) {
    outcome.receivedRows = r.count;
    repo.db.transaction(() {
      for (final json in r.folders) {
        final FolderRecord f;
        try {
          f = FolderRecord.fromJson(json);
        } on Object catch (e) {
          outcome.invalidRows++;
          peers.quarantine(peerId, 'folder', '$e', jsonEncode(json));
          continue;
        }
        _count(_applier.applyFolder(f));
      }
      for (final json in r.notes) {
        final NoteRecord n;
        try {
          n = NoteRecord.fromJson(json);
          if (!n.purged) decodeOps(n.body);
        } on Object catch (e) {
          // One unreadable row must not block every later sync, and must not
          // vanish either: it is kept aside for inspection.
          outcome.invalidRows++;
          peers.quarantine(peerId, 'note', '$e', jsonEncode(json));
          continue;
        }
        final res = _applier.applyNote(n);
        _count(res);
        if (res.conflictCopyId != null) outcome.conflictCopies++;
      }
      if (r.reset) {
        peers.setReceived(peerId, r.upTo);
      } else {
        peers.advance(peerId, received: r.upTo);
      }
    });
  }

  void _count(ApplyResult res) {
    switch (res.kind) {
      case ApplyKind.created:
        outcome.created++;
      case ApplyKind.updated:
        outcome.updated++;
      case ApplyKind.unchanged:
        outcome.unchanged++;
    }
  }

  // ----------------------------------------------------------- attachments

  Future<void> _exchangeAttachments() async {
    final wanted = repo.missingAttachments().take(SyncLimits.maxNeed).toList();
    await _ms.send({'t': 'need', 'hashes': wanted});
    final theirNeed = await _recv('need');
    final hashes = theirNeed['hashes'];
    if (hashes is! List || hashes.length > SyncLimits.maxNeed) {
      throw SyncProtocolException('bad attachment request');
    }
    final serving = _serve([for (final h in hashes) '$h'])..ignore();
    await _receiveBlobs(wanted.toSet());
    await serving;
    outcome.attachmentsStillMissing = repo.missingAttachments().length;
  }

  Future<void> _serve(List<String> hashes) async {
    for (final h in hashes) {
      final bytes = RegExp(r'^[0-9a-f]{64}$').hasMatch(h)
          ? repo.getAttachment(h)
          : null;
      if (bytes == null) {
        await _ms.send({'t': 'blobmissing', 'h': h});
        continue;
      }
      final mime =
          repo.db.select('SELECT mime FROM attachments WHERE hash = ?', [
                h,
              ]).first['mime']
              as String;
      final n = (bytes.length / SyncLimits.blobChunk).ceil().clamp(1, 1 << 30);
      for (var i = 0; i < n; i++) {
        final from = i * SyncLimits.blobChunk;
        final to = (from + SyncLimits.blobChunk).clamp(0, bytes.length);
        await _ms.send({
          't': 'blob',
          'h': h,
          'mime': mime,
          'size': bytes.length,
          'i': i,
          'n': n,
          'd': base64Encode(bytes.sublist(from, to)),
        });
      }
      outcome.attachmentsSent++;
    }
    await _ms.send({'t': 'blobsdone'});
  }

  Future<void> _receiveBlobs(Set<String> wanted) async {
    final parts = <String, BytesBuilder>{};
    final next = <String, int>{};
    final answered = <String>{};
    var total = 0;
    while (true) {
      final m = await _recv();
      switch (m['t']) {
        case 'blobsdone':
          return;
        case 'blobmissing':
          // One answer per requested image, never more.
          final h = '${m['h']}';
          if (!wanted.contains(h) || !answered.add(h)) {
            throw SyncProtocolException('unexpected image reply');
          }
        case 'blob':
          final h = '${m['h']}';
          if (!wanted.contains(h) || answered.contains(h)) {
            throw SyncProtocolException('unrequested image');
          }
          final i = _int(m['i']);
          final n = _int(m['n']);
          final size = _int(m['size']);
          if (size > SyncLimits.maxAttachment || n < 1 || i != (next[h] ?? 0)) {
            throw SyncProtocolException('bad image data');
          }
          final chunk = base64Decode('${m['d']}');
          total += chunk.length;
          if (total > SyncLimits.maxAttachmentBytesPerSession) {
            throw SyncProtocolException('too much image data in one session');
          }
          final b = parts.putIfAbsent(h, BytesBuilder.new)..add(chunk);
          next[h] = i + 1;
          if (b.length > SyncLimits.maxAttachment) {
            throw SyncProtocolException('image too large');
          }
          if (i == n - 1) {
            final bytes = b.toBytes();
            parts.remove(h);
            next.remove(h);
            answered.add(h);
            if (bytes.length == size && sha256Hex(bytes) == h) {
              repo.putAttachment(bytes, '${m['mime']}');
              outcome.attachmentsReceived++;
            }
          }
        default:
          throw SyncProtocolException(
            'unexpected ${m['t']} while receiving images',
          );
      }
    }
  }

  static int _int(Object? v) {
    if (v is int && v >= 0) return v;
    throw SyncProtocolException('expected a non-negative integer');
  }
}

class _Received {
  final folders = <Map<String, Object?>>[];
  final notes = <Map<String, Object?>>[];
  int count = 0;
  int upTo = 0;
  bool reset = false;
}

/// For the UI: a short, plain-language description of how a sync ended.
String describeSyncError(Object e) {
  if (e is SyncTimeoutException) return e.toString();
  if (e is ClockSkewException) return e.toString();
  if (e is HandshakeException) return e.message;
  if (e is TransportClosed) return 'The connection was lost.';
  if (e is ChannelIntegrityException) {
    return 'The connection was corrupted and was dropped.';
  }
  if (e is SyncProtocolException) {
    return 'The other device sent unexpected data.';
  }
  return '$e';
}

/// Which of the two devices should open the connection when both are
/// reachable: the one with the lower id, so they do not both dial at once.
bool shouldDial(String myId, String peerId) => myId.compareTo(peerId) < 0;
