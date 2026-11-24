import 'dart:convert';
import 'dart:typed_data';

import '../../core/version_vector.dart';
import '../../data/models.dart';
import '../../data/note_repository.dart';
import '../merge.dart';
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
  CloudSyncProgress progress = const CloudSyncProgress();

  String? get libraryId => repo.db.getMeta('cloud.library_id');
  int get pullSeq => int.tryParse(repo.db.getMeta('cloud.pull_seq') ?? '') ?? 0;
  int get pushSeq => int.tryParse(repo.db.getMeta('cloud.push_seq') ?? '') ?? 0;

  Future<void> sync() async {
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
        if (e.kind != CloudErrorKind.conflict || round == 4) rethrow;
      }
    }
  }

  Future<void> _syncBlobs() async {
    final hashes = [
      for (final row in repo.db.select(
        'SELECT hash FROM attachments ORDER BY hash',
      ))
        row['hash'] as String,
    ];
    for (var i = 0; i < hashes.length; i += 100) {
      final group = hashes.skip(i).take(100).toList();
      final state = await api.checkBlobs(group);
      for (final hash in group) {
        final local = repo.db.select(
          'SELECT mime,size,data FROM attachments WHERE hash=?',
          [hash],
        ).first;
        final data = local['data'] as Uint8List?;
        if (data != null &&
            (state.missing.contains(hash) || state.partial.containsKey(hash))) {
          var offset = state.partial[hash] ?? 0;
          while (offset < data.length) {
            final end = (offset + 96 * 1024).clamp(0, data.length);
            final next = await api.putBlobChunk(
              hash,
              offset,
              data.length,
              local['mime'] as String,
              Uint8List.fromList(data.sublist(offset, end)),
            );
            if (next <= offset && next < data.length) {
              throw const CloudApiException(
                CloudErrorKind.network,
                'Attachment upload did not advance.',
              );
            }
            offset = next;
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
          size ??= part.size;
          mime ??= part.mime;
          if (size != part.size ||
              part.offset != offset ||
              part.data.isEmpty && !part.complete ||
              size > 50 * 1024 * 1024) {
            throw const CloudApiException(
              CloudErrorKind.malformed,
              'Cloud attachment data is malformed.',
            );
          }
          builder.add(part.data);
          offset += part.data.length;
          complete = part.complete;
        }
        if (offset != size) {
          throw const CloudApiException(
            CloudErrorKind.malformed,
            'Cloud attachment length does not match.',
          );
        }
        repo.storeCloudAttachment(hash, mime!, builder.takeBytes());
      } on CloudApiException catch (e) {
        if (e.kind != CloudErrorKind.notFound) rethrow;
      }
    }
  }

  Future<void> _pull(String library) async {
    var cursor = pullSeq;
    while (true) {
      final page = await api.changes(library, cursor);
      if (page.libraryId != library || page.next < cursor) {
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'Cloud returned an inconsistent change page.',
        );
      }
      repo.db.transaction(() {
        final ordered = page.rows.toList()
          ..sort((a, b) => a.seq.compareTo(b.seq));
        for (final remote in ordered) {
          if (remote.seq <= cursor) continue;
          try {
            _apply(remote);
          } on Object catch (e) {
            // Keep a bounded diagnostic, and advance past an unparseable row
            // so a hostile record cannot wedge every future sync.
            final raw = jsonEncode(remote.toJson());
            repo.db.execute(
              'INSERT INTO quarantine(peer_id,kind,received_at,reason,raw) VALUES(?,?,?,?,?)',
              [
                'cloud',
                remote.kind,
                _now(),
                e.runtimeType.toString(),
                raw.length > 65536 ? raw.substring(0, 65536) : raw,
              ],
            );
            repo.db.execute(
              'DELETE FROM quarantine WHERE id NOT IN (SELECT id FROM quarantine ORDER BY id DESC LIMIT 100)',
            );
          }
          if (remote.seq > cursor) cursor = remote.seq;
        }
        repo.db.setMeta('cloud.pull_seq', '$cursor');
      });
      if (!page.more) break;
      if (page.next <= cursor && page.rows.isEmpty) break;
      cursor = page.next > cursor ? page.next : cursor;
    }
  }

  void _apply(CloudRecord remote) {
    if (remote.kind != 'note' && remote.kind != 'folder') {
      throw const FormatException('Unknown record kind.');
    }
    if (remote.id != remote.row['id'] ||
        recordDigest(remote.row) != remote.digest) {
      throw const FormatException('Invalid row identity or digest.');
    }
    if (remote.kind == 'folder') {
      final record = FolderRecord.fromJson(remote.row);
      RemoteApplier(repo).applyFolder(record);
      _saveCloud(remote, baseTitle: record.name);
      return;
    }
    final record = NoteRecord.fromJson(remote.row);
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
        for (final h in [
          record.contentHlc,
          record.pinnedHlc,
          record.archivedHlc,
          record.folderHlc,
          record.trashedHlc,
          record.conflictHlc,
        ]) {
          repo.db.clock.observe(h);
        }
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
    final candidates = repo.cloudRecordsSince(cursor, limit: 10000);
    int? firstBlocked;
    // Folders always precede notes, including rows in a later local sequence.
    for (final kind in ['folder', 'note']) {
      final pending = candidates.where((r) => r.kind == kind).toList();
      final batches = _boundedBatches(
        pending,
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
            if (missing.isNotEmpty) {
              firstBlocked ??= item.seq;
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
            cursor = item.seq > cursor ? item.seq : cursor;
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
          cursor = batch.last.seq > cursor ? batch.last.seq : cursor;
        });
      }
    }
    final blocked = firstBlocked;
    if (blocked != null && blocked - 1 < cursor) {
      cursor = blocked - 1;
    } else if (candidates.isNotEmpty && candidates.last.seq > cursor) {
      cursor = candidates.last.seq;
    }
    repo.db.transaction(() => repo.db.setMeta('cloud.push_seq', '$cursor'));
  }
}

List<List<T>> _boundedBatches<T>(List<T> rows, String Function(T) encode) {
  final result = <List<T>>[];
  var current = <T>[];
  var bytes = 0;
  for (final row in rows) {
    final size = utf8.encode(encode(row)).length + 128;
    if (size > 240 * 1024) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'A record is too large to sync.',
      );
    }
    if (current.isNotEmpty &&
        (current.length >= 50 || bytes + size > 240 * 1024)) {
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
