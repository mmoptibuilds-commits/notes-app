import 'dart:convert';

import '../core/hlc.dart';
import '../core/version_vector.dart';
import '../data/models.dart';
import '../data/note_repository.dart';

/// Result of merging two versions of one note.
class NoteMerge {
  const NoteMerge(this.merged, this.conflictLoser);

  /// The note both devices end up with.
  final NoteRecord merged;

  /// Content that lost a concurrent edit and must be kept as a separate
  /// conflict copy, or null when nothing needs preserving.
  final NoteRecord? conflictLoser;
}

/// Merges two versions of a note. Symmetric: `mergeNotes(a, b)` and
/// `mergeNotes(b, a)` give identical results, which is what lets devices
/// converge without coordinating.
///
/// Content (title + body, or deletion) follows the version vector:
///  * one side includes the other: it wins;
///  * independent edits: the later clock wins and the other is returned as
///    [NoteMerge.conflictLoser];
///  * an edit beats an independent delete-forever (nothing is lost).
/// Pinned, archived, folder, trash and conflict flags are independent
/// last-writer-wins registers.
NoteMerge mergeNotes(NoteRecord a, NoteRecord b) {
  assert(a.id == b.id);
  NoteRecord winner;
  NoteRecord? loser;
  switch (a.contentVv.compare(b.contentVv)) {
    case VvOrder.dominates:
      winner = a;
    case VvOrder.dominated:
      winner = b;
    case VvOrder.equal:
      if (a.title == b.title && a.body == b.body && a.purged == b.purged) {
        winner = a;
        break;
      }
      // The same version with different content should be impossible (a bug
      // or a damaged peer). Keep both rather than choose silently.
      continue concurrent;
    concurrent:
    case VvOrder.concurrent:
      if (a.purged != b.purged) {
        winner = a.purged ? b : a;
      } else {
        winner = _later(a, b);
        final other = identical(winner, a) ? b : a;
        if (!other.purged) loser = other;
      }
  }
  final merged = NoteRecord(
    id: a.id,
    title: winner.title,
    body: winner.body,
    createdAt: a.createdAt < b.createdAt ? a.createdAt : b.createdAt,
    updatedAt: winner.updatedAt,
    contentHlc: winner.contentHlc,
    contentVv: a.contentVv.merge(b.contentVv),
    purged: winner.purged,
    pinned: _lww(a.pinnedHlc, a.pinned, b.pinnedHlc, b.pinned),
    pinnedHlc: _maxHlc(a.pinnedHlc, b.pinnedHlc),
    archived: _lww(a.archivedHlc, a.archived, b.archivedHlc, b.archived),
    archivedHlc: _maxHlc(a.archivedHlc, b.archivedHlc),
    folderId: _lww(a.folderHlc, a.folderId, b.folderHlc, b.folderId),
    folderHlc: _maxHlc(a.folderHlc, b.folderHlc),
    trashedAt: _lww(a.trashedHlc, a.trashedAt, b.trashedHlc, b.trashedAt),
    trashedHlc: _maxHlc(a.trashedHlc, b.trashedHlc),
    conflictOf: _lww(a.conflictHlc, a.conflictOf, b.conflictHlc, b.conflictOf),
    conflictHlc: _maxHlc(a.conflictHlc, b.conflictHlc),
  );
  return NoteMerge(NoteRepository.normalise(merged), loser);
}

/// Merges two versions of a folder (name and deletion are separate
/// last-writer-wins registers).
FolderRecord mergeFolders(FolderRecord a, FolderRecord b) => FolderRecord(
  id: a.id,
  name: _lww(a.nameHlc, a.name, b.nameHlc, b.name),
  nameHlc: _maxHlc(a.nameHlc, b.nameHlc),
  deleted: _lww(a.deletedHlc, a.deleted, b.deletedHlc, b.deleted),
  deletedHlc: _maxHlc(a.deletedHlc, b.deletedHlc),
  createdAt: a.createdAt < b.createdAt ? a.createdAt : b.createdAt,
);

NoteRecord _later(NoteRecord a, NoteRecord b) {
  final c = a.contentHlc.compareTo(b.contentHlc);
  if (c != 0) return c > 0 ? a : b;
  // Same clock and node (should not happen): decide by content so both
  // sides still pick the same one.
  return '${a.title}\u0000${a.body}'.compareTo('${b.title}\u0000${b.body}') >= 0
      ? a
      : b;
}

Hlc _maxHlc(Hlc a, Hlc b) => a >= b ? a : b;

T _lww<T>(Hlc ha, T va, Hlc hb, T vb) {
  final c = ha.compareTo(hb);
  if (c != 0) return c > 0 ? va : vb;
  return '$va'.compareTo('$vb') >= 0 ? va : vb;
}

extension on Hlc {
  bool operator >=(Hlc o) => compareTo(o) >= 0;
}

enum ApplyKind { created, updated, unchanged }

class ApplyResult {
  const ApplyResult(this.kind, {this.conflictCopyId});
  final ApplyKind kind;
  final String? conflictCopyId;
}

/// A peer sent a clock reading far in the future. Accepting it would push
/// this device's clock (and every later edit) ahead of real time forever.
class ClockSkewException implements Exception {
  ClockSkewException(this.skew);
  final Duration skew;
  @override
  String toString() =>
      'Peer clock is ${skew.inHours} hours ahead; refusing to sync.';
}

/// Applies records received from a peer to the local database.
///
/// Idempotent and order-independent: receiving the same record twice, or
/// records out of order, ends in the same state.
class RemoteApplier {
  RemoteApplier(this.repo, {int Function()? nowMs, this.maxFutureSkew})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final NoteRepository repo;
  final int Function() _now;

  /// Largest tolerated gap between a received clock reading and local time.
  final Duration? maxFutureSkew;

  Duration get _limit => maxFutureSkew ?? const Duration(days: 2);

  void _check(Iterable<Hlc> stamps) {
    final latest = stamps.map((h) => h.millis).reduce((a, b) => a > b ? a : b);
    final skew = latest - _now();
    if (skew > _limit.inMilliseconds) {
      throw ClockSkewException(Duration(milliseconds: skew));
    }
  }

  ApplyResult applyNote(NoteRecord remote) {
    final stamps = [
      remote.contentHlc,
      remote.pinnedHlc,
      remote.archivedHlc,
      remote.folderHlc,
      remote.trashedHlc,
      remote.conflictHlc,
    ];
    _check(stamps);
    return repo.db.transaction(() {
      for (final h in stamps) {
        repo.db.clock.observe(h);
      }
      final local = repo.getRecord(remote.id);
      if (local == null) {
        repo.writeRecord(remote);
        return const ApplyResult(ApplyKind.created);
      }
      final r = mergeNotes(local, remote);
      String? copy;
      if (r.conflictLoser != null) {
        copy = repo.insertConflictCopyIfAbsent(r.conflictLoser!);
      }
      if (_same(r.merged, local)) {
        return ApplyResult(ApplyKind.unchanged, conflictCopyId: copy);
      }
      repo.writeRecord(r.merged);
      return ApplyResult(ApplyKind.updated, conflictCopyId: copy);
    });
  }

  ApplyResult applyFolder(FolderRecord remote) {
    _check([remote.nameHlc, remote.deletedHlc]);
    return repo.db.transaction(() {
      repo.db.clock
        ..observe(remote.nameHlc)
        ..observe(remote.deletedHlc);
      final local = repo.getFolderRecord(remote.id);
      if (local == null) {
        repo.writeFolderRecord(remote);
        return const ApplyResult(ApplyKind.created);
      }
      final merged = mergeFolders(local, remote);
      if (jsonEncode(merged.toJson()) == jsonEncode(local.toJson())) {
        return const ApplyResult(ApplyKind.unchanged);
      }
      repo.writeFolderRecord(merged);
      return const ApplyResult(ApplyKind.updated);
    });
  }

  static bool _same(NoteRecord a, NoteRecord b) =>
      jsonEncode(a.toJson()) == jsonEncode(b.toJson());
}
