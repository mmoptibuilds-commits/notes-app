/// A local, encrypted snapshot of editor content whose normal save has not
/// completed. Drafts are device-only and are never part of sync.
class PendingEditorDraft {
  const PendingEditorDraft({
    required this.id,
    required this.noteId,
    required this.folderId,
    required this.title,
    required this.body,
    required this.baseVv,
    required this.updatedAt,
  });

  final String id;
  final String? noteId;
  final String? folderId;
  final String title;

  /// Canonical Quill Delta JSON using the same representation as note bodies.
  final String body;

  /// The version the editor last loaded or saved, used to preserve concurrent
  /// changes as a conflict copy when this draft is recovered.
  final String baseVv;
  final int updatedAt;
}

class EditorDraftWriteResult {
  const EditorDraftWriteResult({
    required this.noteId,
    required this.baseVv,
    this.conflictCopyId,
  });

  final String noteId;
  final String baseVv;
  final String? conflictCopyId;
}

class EditorDraftUnavailableException implements Exception {
  const EditorDraftUnavailableException();

  @override
  String toString() =>
      'This recovery draft was already recovered or discarded on another screen.';
}
