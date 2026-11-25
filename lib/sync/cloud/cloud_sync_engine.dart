import 'dart:convert';
import 'dart:typed_data';

import '../../core/version_vector.dart';
import '../../data/models.dart';
import '../../data/note_repository.dart';
import '../merge.dart' show ClockSkewException, RemoteApplier;
import '../three_way.dart';
import 'cloud_api.dart';
import 'record_digest.dart';

class CloudSyncProgress {
  const CloudSyncProgress({this.uploaded = 0, this.total = 0});
  final int uploaded, total;
}

/// Pulls and pushes revisioned cloud rows. Each server page and push batch is
/// committed locally in its own SQLite transaction.
class CloudSyncEngine {
  CloudSyncEngine(this.repo, this.api, {int Function()? nowMs})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  final NoteRepository repo;
  final CloudApi api;
  final int Function() _now;

  /// True while this engine writes cloud rows into the local database, so the
  /// service does not treat those writes as new local edits.
  bool applyingRemote = false;
  CloudSyncProgress progress = const CloudSyncProgress();
  final Set<String> unavailableBlobs = {};
  final Set<String> oversizedRows = {};
  final Set<String> oversizedAttachments = {};
  int get quarantinedRows =>
      repo.db
              .select(
                "SELECT count(*) AS n FROM quarantine WHERE peer_id='cloud'",
              )
              .first['n']
          as int;
  bool _cancelled = false;

  void cancel() => _cancelled = true;
  void resume() => _cancelled = false;

  void _checkActive() {
    if (_cancelled) {
      throw const CloudApiException(
        CloudErrorKind.network,
        'Cloud sync was paused.',
      );
    }
  }

  String? get libraryId => repo.db.getMeta('cloud.library_id');
  int get pullSeq => int.tryParse(repo.db.getMeta('cloud.pull_seq') ?? '') ?? 0;
  int get pushSeq => int.tryParse(repo.db.getMeta('cloud.push_seq') ?? '') ?? 0;

  Future<void> sync() async {
    _checkActive();
    unavailableBlobs.clear();
    oversizedAttachments.clear();
    final library = libraryId;
    if (library == null) {
      throw const CloudApiException(
        CloudErrorKind.notFound,
        'No cloud library is linked.',
      );
    }
    for (var round = 0; round < 5; round++) {
      await _pull(library);
      await _syncBlobs();
      try {
        await _push(library);
        return;
      } on CloudApiException catch (e) {
        if (e.kind != CloudErrorKind.conflict) rethrow;
        if (round == 4) {
          throw const CloudApiException(
            CloudErrorKind.conflict,
            'Cloud sync could not converge after 5 conflict rounds.',
          );
        }
        // A push conflict is itself a change feed response. Applying those
        // rows avoids waiting for a possibly stale head cursor.
        await _applyConflictRows(library, e.currentRows);
      }
    }
  }

  Future<void> _syncBlobs() async {
    var downloadedBytes = 0;
    final hashes = [
      for (final row in repo.db.select(
        'SELECT hash FROM attachments ORDER BY hash',
      ))
        row['hash'] as String,
    ];
    for (var i = 0; i < hashes.length; i += 100) {
      final group = hashes.skip(i).take(100).toList();
      late final ({Set<String> missing, Map<String, int> partial}) state;
      try {
        state = await api.checkBlobs(group);
        _checkActive();
      } on CloudApiException {
        _checkActive();
        unavailableBlobs.addAll(group);
        continue;
      }
      for (final hash in group) {
        final local = repo.db.select(
          'SELECT mime,size,data FROM attachments WHERE hash=?',
          [hash],
        ).first;
        final data = local['data'] as Uint8List?;
        if ((local['size'] as int) > 20 * 1024 * 1024) {
          oversizedAttachments.add(hash);
          continue;
        }
        if (data != null &&
            (state.missing.contains(hash) || state.partial.containsKey(hash))) {
          var offset = state.partial[hash] ?? 0;
          try {
            while (offset < data.length) {
              final end = (offset + 96 * 1024).clamp(0, data.length);
              final next = await api.putBlobChunk(
                hash,
                offset,
                data.length,
                local['mime'] as String,
                Uint8List.fromList(data.sublist(offset, end)),
              );
              _checkActive();
              if (next <= offset && next < data.length) {
                throw const CloudApiException(
                  CloudErrorKind.malformed,
                  'Attachment upload did not advance.',
                );
              }
              if (next > data.length) {
                throw const CloudApiException(
                  CloudErrorKind.malformed,
                  'Attachment upload offset is invalid.',
                );
              }
              offset = next;
            }
          } on CloudApiException {
            _checkActive();
            unavailableBlobs.add(hash);
          }
        }
      }
    }
    // Placeholders are created from note embeds. A missing remote blob is
    // tolerated; a present blob is assembled and hash-checked before storage.
    for (final hash in repo.missingAttachments()) {
      try {
        var offset = 0;
        int? size;
        String? mime;
        final builder = BytesBuilder();
        var complete = false;
        while (!complete) {
          final part = await api.getBlobChunk(hash, offset);
          _checkActive();
          size ??= part.size;
          mime ??= part.mime;
          if (size != part.size ||
              part.offset != offset ||
              part.data.isEmpty && !part.complete ||
              size < 0 ||
              size > 20 * 1024 * 1024 ||
              part.data.length > size - offset ||
              downloadedBytes + part.data.length > 200 * 1024 * 1024) {
            throw const CloudApiException(
              CloudErrorKind.malformed,
              'Cloud attachment data is malformed.',
            );
          }
          builder.add(part.data);
          offset += part.data.length;
          downloadedBytes += part.data.length;
          complete = part.complete;
        }
        if (offset != size) {
          throw const CloudApiException(
            CloudErrorKind.malformed,
            'Cloud attachment length does not match.',
          );
        }
        applyingRemote = true;
        try {
          repo.storeCloudAttachment(hash, mime!, builder.takeBytes());
        } finally {
          applyingRemote = false;
        }
      } on CloudApiException catch (e) {
        if (e.kind == CloudErrorKind.notFound ||
            e.kind == CloudErrorKind.malformed) {
          unavailableBlobs.add(hash);
        } else {
          rethrow;
        }
      } on FormatException {
        unavailableBlobs.add(hash);
      }
    }
  }

  Future<void> _pull(String library) async {
    _retryQuarantine();
    var cursor = pullSeq;
    var pages = 0;
    while (true) {
      if (++pages > 10000) {
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'Cloud returned too many change pages.',
        );
      }
      final page = await api.changes(library, cursor);
      _checkActive();
      if (page.libraryId != library ||
          page.next < cursor ||
          page.rows.length > 100 ||
          page.head < cursor ||
          page.head < page.next) {
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'Cloud returned an inconsistent change page.',
        );
      }
      final ids = <String>{};
      var previousSeq = cursor;
      for (final remote in page.rows) {
        if (remote.seq <= previousSeq ||
            !ids.add('${remote.kind}:${remote.id}')) {
          throw const CloudApiException(
            CloudErrorKind.malformed,
            'Cloud returned an invalid change page.',
          );
        }
        previousSeq = remote.seq;
      }
      if ((page.rows.isNotEmpty && page.next != previousSeq) ||
          (page.rows.isEmpty && (page.more || page.head > cursor)) ||
          (page.more && page.next >= page.head)) {
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'Cloud returned an inconsistent change cursor.',
        );
      }
      applyingRemote = true;
      try {
        repo.db.transaction(() {
          for (final remote in page.rows) {
            try {
              repo.db.savepoint(() => _apply(remote));
              _deleteQuarantineFor(remote);
            } on ClockSkewException {
              throw const CloudApiException(
                CloudErrorKind.malformed,
                "This device's or another device's clock looks wrong. Cloud sync stopped.",
              );
            } on Object catch (e) {
              // Malformed rows are isolated with a savepoint, then quarantined.
              final raw = jsonEncode(remote.toJson());
              final rawBytes = utf8.encode(raw);
              final boundedRaw = rawBytes.length > 256 * 1024
                  ? utf8.decode(
                      rawBytes.sublist(0, 256 * 1024),
                      allowMalformed: true,
                    )
                  : raw;
              for (final old in repo.db.select(
                "SELECT id,raw FROM quarantine WHERE peer_id='cloud' AND kind=?",
                [remote.kind],
              )) {
                try {
                  final decoded = jsonDecode(old['raw'] as String);
                  if (decoded is Map && decoded['id'] == remote.id) {
                    repo.db.execute('DELETE FROM quarantine WHERE id=?', [
                      old['id'],
                    ]);
                  }
                } on Object {
                  // An unreadable older quarantine item cannot shadow the new row.
                }
              }
              repo.db.execute(
                'INSERT INTO quarantine(peer_id,kind,received_at,reason,raw) VALUES(?,?,?,?,?)',
                [
                  'cloud',
                  remote.kind,
                  _now(),
                  e.runtimeType.toString(),
                  boundedRaw,
                ],
              );
              repo.db.execute(
                'DELETE FROM quarantine WHERE id NOT IN (SELECT id FROM quarantine ORDER BY id DESC LIMIT 100)',
              );
            }
            cursor = remote.seq;
          }
          repo.db.setMeta('cloud.pull_seq', '$cursor');
        });
      } finally {
        applyingRemote = false;
      }
      if (!page.more) break;
      cursor = page.next;
    }
  }

  void _retryQuarantine() {
    final rows = repo.db.select(
      "SELECT id,raw FROM quarantine WHERE peer_id='cloud' ORDER BY id",
    );
    for (final entry in rows) {
      try {
        final decoded = jsonDecode(entry['raw'] as String);
        if (decoded is! Map) continue;
        final remote = CloudRecord.fromJson(decoded.cast<String, Object?>());
        applyingRemote = true;
        try {
          repo.db.transaction(() => repo.db.savepoint(() => _apply(remote)));
        } finally {
          applyingRemote = false;
        }
        repo.db.execute('DELETE FROM quarantine WHERE id=?', [entry['id']]);
        _deleteQuarantineFor(remote);
      } on Object {
        // Keep malformed rows for a later pull retry.
      }
    }
  }

  void _deleteQuarantineFor(CloudRecord remote) {
    for (final old in repo.db.select(
      "SELECT id,raw FROM quarantine WHERE peer_id='cloud' AND kind=?",
      [remote.kind],
    )) {
      try {
        final decoded = jsonDecode(old['raw'] as String);
        if (decoded is Map && decoded['id'] == remote.id) {
          repo.db.execute('DELETE FROM quarantine WHERE id=?', [old['id']]);
        }
      } on Object {
        // An unreadable quarantine item has no reliable record identity.
      }
    }
  }

  Future<void> _applyConflictRows(
    String library,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty || rows.length > 50) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Cloud returned an invalid conflict response.',
      );
    }
    final parsed = <CloudRecord>[];
    final missing = <(String, String)>[];
    for (final row in rows) {
      if (row['missing'] == true) {
        final kind = row['kind'];
        final id = row['id'];
        if ((kind != 'note' && kind != 'folder') ||
            id is! String ||
            !_isUuid(id)) {
          throw const CloudApiException(
            CloudErrorKind.malformed,
            'Cloud returned an invalid missing-record conflict.',
          );
        }
        missing.add((kind as String, id));
        continue;
      }
      parsed.add(CloudRecord.fromJson(row));
    }
    final head = await api.head();
    _checkActive();
    if (head['libraryId'] != library) {
      throw const CloudApiException(
        CloudErrorKind.libraryMismatch,
        'Cloud library changed.',
      );
    }
    repo.db.transaction(() {
      // A nonzero base revision with no current server row means the server
      // lost/deleted the row. Forget only its server revision so the next
      // round retries the still-local record as a fresh insert (baseRev 0).
      for (final (kind, id) in missing) {
        repo.db.execute('DELETE FROM cloud_notes WHERE kind=? AND id=?', [
          kind,
          id,
        ]);
      }
      for (final remote in parsed) {
        try {
          repo.db.savepoint(() => _apply(remote));
        } on ClockSkewException {
          throw const CloudApiException(
            CloudErrorKind.malformed,
            "This device's or another device's clock looks wrong. Cloud sync stopped.",
          );
        } on Object {
          rethrow;
        }
      }
      // Conflict records may have seqs beyond the durable pull cursor. The
      // ordinary feed remains authoritative for cursor advancement.
    });
  }

  void _apply(CloudRecord remote) {
    if (remote.kind != 'note' && remote.kind != 'folder') {
      throw const FormatException('Unknown record kind.');
    }
    if ((remote.kind != 'note' && remote.kind != 'folder') ||
        remote.id != remote.row['id'] ||
        !_isUuid(remote.id) ||
        remote.rev < 1 ||
        remote.seq < 1 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(remote.digest) ||
        recordDigest(remote.row) != remote.digest) {
      throw const FormatException('Invalid row identity or digest.');
    }
    if (remote.kind == 'folder') {
      final record = FolderRecord.fromJson(remote.row);
      _checkSkew([record.nameHlc, record.deletedHlc]);
      repo.db.clock
        ..observe(record.nameHlc)
        ..observe(record.deletedHlc);
      RemoteApplier(repo).applyFolder(record);
      _saveCloud(remote, baseTitle: record.name);
      return;
    }
    final record = NoteRecord.fromJson(remote.row);
    final stamps = [
      record.contentHlc,
      record.pinnedHlc,
      record.archivedHlc,
      record.folderHlc,
      record.trashedHlc,
      record.conflictHlc,
    ];
    _checkSkew(stamps);
    for (final h in stamps) {
      repo.db.clock.observe(h);
    }
    final local = repo.getRecord(record.id);
    if (local == null) {
      RemoteApplier(repo).applyNote(record);
    } else {
      final baseRow = repo.db.select(
        "SELECT base_title,base_body,base_vv FROM cloud_notes WHERE kind='note' AND id=?",
        [record.id],
      );
      MergeBase? base;
      if (baseRow.isNotEmpty && baseRow.first['base_vv'] != null) {
        base = MergeBase(
          title: baseRow.first['base_title'] as String,
          body: baseRow.first['base_body'] as String,
          contentVv: VersionVector.decode(baseRow.first['base_vv'] as String),
        );
      }
      final merged = mergeNotesThreeWay(
        local,
        record,
        base: base,
        node: repo.db.deviceId,
        now: repo.db.clock.now(),
      );
      repo.db.transaction(() {
        if (merged.conflictLoser case final loser?) {
          repo.insertConflictCopyIfAbsent(loser);
        }
        if (recordDigest(local) != recordDigest(merged.merged)) {
          repo.writeRecord(merged.merged);
        }
      });
    }
    _saveCloud(
      remote,
      baseTitle: record.title,
      baseBody: record.body,
      baseVv: record.contentVv.encode(),
      baseHlc: record.contentHlc.encode(),
    );
  }

  bool _isUuid(String value) => RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value);

  void _checkSkew(Iterable<dynamic> stamps) {
    final latest = stamps
        .map((h) => h.millis as int)
        .reduce((a, b) => a > b ? a : b);
    final skew = latest - _now();
    if (skew > const Duration(days: 2).inMilliseconds) {
      throw ClockSkewException(Duration(milliseconds: skew));
    }
  }

  void _saveCloud(
    CloudRecord r, {
    String? baseTitle,
    String? baseBody,
    String? baseVv,
    String? baseHlc,
  }) {
    repo.db.execute(
      '''INSERT INTO cloud_notes(kind,id,rev,digest,base_title,base_body,base_vv,base_hlc) VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(kind,id) DO UPDATE SET rev=excluded.rev,digest=excluded.digest,base_title=excluded.base_title,base_body=excluded.base_body,base_vv=excluded.base_vv,base_hlc=excluded.base_hlc''',
      [r.kind, r.id, r.rev, r.digest, baseTitle, baseBody, baseVv, baseHlc],
    );
  }

  Future<void> _push(String library) async {
    var cursor = pushSeq;
    var scanCursor = cursor;
    var cursorBlocked = false;
    while (true) {
      final candidates = repo.cloudRecordsSince(scanCursor, limit: 300);
      if (candidates.isEmpty) break;
      final completed = <int>{};
      // Folders always precede notes within each bounded page.
      for (final kind in ['folder', 'note']) {
        final pending = candidates.where((r) => r.kind == kind).toList();
        final eligible = <({int seq, String kind, Object record})>[];
        for (final item in pending) {
          final row = switch (item.record) {
            NoteRecord n => n.toJson(),
            FolderRecord f => f.toJson(),
            _ => const <String, Object?>{},
          };
          final id = row['id'] as String? ?? '';
          final key = '$kind:$id';
          if (utf8.encode(jsonEncode(row)).length > 180 * 1024) {
            oversizedRows.add(key);
          } else {
            oversizedRows.remove(key);
            eligible.add(item);
          }
        }
        final batches = _boundedBatches(
          eligible,
          (item) => jsonEncode(switch (item.record) {
            NoteRecord n => n.toJson(),
            FolderRecord f => f.toJson(),
            _ => const {},
          }),
        );
        for (final batch in batches) {
          final items = <CloudPushItem>[];
          for (final item in batch) {
            if (item.record case final NoteRecord note) {
              final missing = repo.db.select(
                '''SELECT 1 FROM note_attachments na JOIN attachments a ON a.hash=na.hash
              WHERE na.note_id=? AND a.data IS NULL LIMIT 1''',
                [note.id],
              );
              final failedRefs = repo.db
                  .select('SELECT hash FROM note_attachments WHERE note_id=?', [
                    note.id,
                  ])
                  .any(
                    (r) =>
                        unavailableBlobs.contains(r['hash']) &&
                        !oversizedAttachments.contains(r['hash']),
                  );
              if (missing.isNotEmpty || failedRefs) {
                continue;
              }
            }
            final row = switch (item.record) {
              NoteRecord n => n.toJson(),
              FolderRecord f => f.toJson(),
              _ => throw StateError('unexpected record'),
            };
            final digest = recordDigest(row);
            final old = repo.db.select(
              'SELECT rev,digest FROM cloud_notes WHERE kind=? AND id=?',
              [kind, row['id']],
            );
            if (old.isNotEmpty && old.first['digest'] == digest) {
              completed.add(item.seq);
              continue;
            }
            items.add(
              CloudPushItem(
                kind,
                row['id'] as String,
                old.isEmpty ? 0 : old.first['rev'] as int,
                digest,
                row,
              ),
            );
          }
          if (items.isEmpty) continue;
          final results = await api.push(
            library,
            '${repo.db.deviceId}-${_now()}-${batch.first.seq}',
            items,
          );
          _checkActive();
          if (results.length != items.length ||
              items.any(
                (item) => !results.any(
                  (result) => result.kind == item.kind && result.id == item.id,
                ),
              )) {
            throw const CloudApiException(
              CloudErrorKind.malformed,
              'Cloud returned incomplete push results.',
            );
          }
          repo.db.transaction(() {
            for (final result in results) {
              final item = items.firstWhere(
                (v) => v.kind == result.kind && v.id == result.id,
              );
              final row = item.row;
              _saveCloud(
                CloudRecord(
                  kind: result.kind,
                  id: result.id,
                  rev: result.rev,
                  seq: result.seq,
                  digest: item.digest,
                  row: row,
                ),
                baseTitle: kind == 'note'
                    ? row['title'] as String
                    : row['name'] as String,
                baseBody: kind == 'note' ? row['body'] as String : null,
                baseVv: kind == 'note' ? jsonEncode(row['contentVv']) : null,
                baseHlc: kind == 'note' ? row['contentHlc'] as String : null,
              );
            }
            for (final item in batch) {
              final row = switch (item.record) {
                NoteRecord note => note.id,
                FolderRecord folder => folder.id,
                _ => '',
              };
              if (items.any((sent) => sent.id == row)) completed.add(item.seq);
            }
          });
        }
      }
      for (final item in candidates) {
        if (cursorBlocked) continue;
        final itemId = switch (item.record) {
          NoteRecord n => n.id,
          FolderRecord f => f.id,
          _ => '',
        };
        if (oversizedRows.contains('${item.kind}:$itemId') ||
            !completed.contains(item.seq)) {
          cursorBlocked = true;
          continue;
        }
        cursor = item.seq;
      }
      repo.db.transaction(() => repo.db.setMeta('cloud.push_seq', '$cursor'));
      if (candidates.length < 300) break;
      scanCursor = candidates.last.seq;
    }
  }
}

List<List<T>> _boundedBatches<T>(List<T> rows, String Function(T) encode) {
  final result = <List<T>>[];
  var current = <T>[];
  var bytes = 0;
  for (final row in rows) {
    final size = utf8.encode(encode(row)).length + 128;
    if (utf8.encode(encode(row)).length > 180 * 1024) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'A record is too large to sync.',
      );
    }
    if (current.isNotEmpty &&
        (current.length >= 50 || bytes + size > 256 * 1024)) {
      result.add(current);
      current = <T>[];
      bytes = 0;
    }
    current.add(row);
    bytes += size;
  }
  if (current.isNotEmpty) result.add(current);
  return result;
}
