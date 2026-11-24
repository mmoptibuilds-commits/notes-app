import '../core/hlc.dart';
import '../core/version_vector.dart';
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
/// PLACEHOLDER: delegates to [mergeNotes] until the three-way implementation
/// lands. Keep the signature.
NoteMerge mergeNotesThreeWay(
  NoteRecord local,
  NoteRecord remote, {
  required MergeBase? base,
  required String node,
  required Hlc now,
}) => mergeNotes(local, remote);
