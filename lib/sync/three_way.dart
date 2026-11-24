import '../core/hlc.dart';
import '../core/version_vector.dart';
import '../data/note_repository.dart';
import '../doc/line_merge.dart';
import 'merge.dart';
import '../data/models.dart';

/// The content two devices last agreed on for a note: the common ancestor of a
/// three-way merge. Kept locally per note after every cloud sync.
class MergeBase {
  const MergeBase({
    required this.title,
    required this.body,
    required this.contentVv,
  });

  final String title;

  /// Quill Delta JSON text, as stored in `notes.body`.
  final String body;
  final VersionVector contentVv;
}

/// Merges [local] and [remote] using [base] as the common ancestor.
///
/// Contract (docs/CLOUD_SYNC.md, section 6): when the two content versions are
/// concurrent, [base] is present and dominated by both, edits to different
/// lines are combined into a new version (vector = maximum plus one increment
/// for [node], clock [now]) with no conflict loser. Overlapping edits, a missing
/// base or any other case fall back to [mergeNotes] (later version is the main
/// note, the other is [NoteMerge.conflictLoser]). Registers (pinned, archived,
/// folder, trash, conflict) always merge as in [mergeNotes].
///
NoteMerge mergeNotesThreeWay(
  NoteRecord local,
  NoteRecord remote, {
  required MergeBase? base,
  required String node,
  required Hlc now,
}) {
  final fallback = mergeNotes(local, remote);
  if (local.contentVv.compare(remote.contentVv) != VvOrder.concurrent ||
      local.purged ||
      remote.purged ||
      base == null ||
      !_baseIncluded(base.contentVv, local.contentVv) ||
      !_baseIncluded(base.contentVv, remote.contentVv)) {
    return fallback;
  }

  final localTitleChanged = local.title != base.title;
  final remoteTitleChanged = remote.title != base.title;
  if (localTitleChanged && remoteTitleChanged && local.title != remote.title) {
    return fallback;
  }
  final title = localTitleChanged ? local.title : remote.title;
  final body = mergeBodies(base.body, local.body, remote.body);
  if (body.isConflict) return fallback;

  final version = fallback.merged.contentVv.increment(node);
  final normalised = NoteRepository.normalise(
    fallback.merged.copyWith(
      title: title,
      body: body.body!,
      contentVv: version,
      contentHlc: now,
      updatedAt: now.millis,
    ),
  );
  // The text merge creates a fresh content clock, but a merge is not a user
  // edit and must not rewrite an independent register. `mergeNotes` already
  // decided whether the trash register survives (a genuinely newer edit
  // restores the note, exactly as on LAN). If it stays trashed, stamp the
  // register with the merge clock too: otherwise `writeRecord` would run
  // `normalise`, see content newer than the trash stamp, and silently restore
  // the note.
  final stillTrashed = fallback.merged.trashedAt;
  final merged = stillTrashed == null
      ? normalised.copyWith(trashedAt: null)
      : normalised.copyWith(trashedAt: stillTrashed, trashedHlc: now);
  return NoteMerge(merged, null);
}

bool _baseIncluded(VersionVector base, VersionVector side) =>
    switch (base.compare(side)) {
      VvOrder.equal || VvOrder.dominated => true,
      VvOrder.dominates || VvOrder.concurrent => false,
    };
