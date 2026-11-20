import 'dart:convert';
import 'dart:typed_data';

import '../data/note_repository.dart';
import '../sync/merge.dart';
import 'notes_export.dart';

/// Read-only preview of one `notes-export` file against the current library.
class NotesRestorePreview {
  const NotesRestorePreview({
    required this.format,
    required this.version,
    required this.exportedAt,
    required this.noteCount,
    required this.folderCount,
    required this.attachmentCount,
    required this.newNotes,
    required this.identicalNotes,
    required this.conflictingNotes,
    required this.potentialConflictCopies,
    required this.newFolders,
    required this.identicalFolders,
    required this.conflictingFolders,
    required this.newAttachments,
    required this.identicalAttachments,
    required this.conflictingAttachments,
  });

  final String format;
  final int version;
  final DateTime exportedAt;
  final int noteCount;
  final int folderCount;
  final int attachmentCount;
  final int newNotes;
  final int identicalNotes;

  /// Same id exists locally, but at least one stored field differs. Sync merge
  /// rules decide the result; this does not always mean a conflict copy.
  final int conflictingNotes;

  /// Differing content versions that [mergeNotes] says need a kept copy.
  final int potentialConflictCopies;
  final int newFolders;
  final int identicalFolders;
  final int conflictingFolders;
  final int newAttachments;
  final int identicalAttachments;
  final int conflictingAttachments;

  String summary() =>
      '$format version $version from ${exportedAt.toLocal()}\n'
      '$noteCount notes: $newNotes new, $identicalNotes identical, '
      '$conflictingNotes with the same id but different data. '
      '$potentialConflictCopies may need a conflict copy.\n'
      '$folderCount folders: $newFolders new, $identicalFolders identical, '
      '$conflictingFolders with the same id but different data.\n'
      '$attachmentCount attachments: $newAttachments to add, '
      '$identicalAttachments already present, '
      '$conflictingAttachments with unexpected local bytes.';
}

/// Result of a committed app-export restore.
class NotesRestoreReport {
  const NotesRestoreReport({
    required this.notesCreated,
    required this.notesUpdated,
    required this.notesUnchanged,
    required this.conflictCopies,
    required this.foldersCreated,
    required this.foldersUpdated,
    required this.foldersUnchanged,
    required this.attachmentsAdded,
    required this.attachmentsAlreadyPresent,
  });

  final int notesCreated;
  final int notesUpdated;
  final int notesUnchanged;
  final int conflictCopies;
  final int foldersCreated;
  final int foldersUpdated;
  final int foldersUnchanged;
  final int attachmentsAdded;
  final int attachmentsAlreadyPresent;

  String summary() =>
      'Notes: $notesCreated added, $notesUpdated merged, '
      '$notesUnchanged unchanged; $conflictCopies conflict copies kept.\n'
      'Folders: $foldersCreated added, $foldersUpdated merged, '
      '$foldersUnchanged unchanged.\n'
      'Attachments: $attachmentsAdded added, '
      '$attachmentsAlreadyPresent already present.';
}

/// Restores the app's own export format through the same record merge rules
/// used by sync. Each apply runs in one repository database transaction.
class NotesExportRestorer {
  NotesExportRestorer(this.repo, {int Function()? nowMs})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final NoteRepository repo;
  final int Function() _now;

  /// Validates and compares without writing to the library.
  NotesRestorePreview inspect(String text) {
    final contents = parseExport(text);
    var newNotes = 0;
    var identicalNotes = 0;
    var conflictingNotes = 0;
    var potentialConflictCopies = 0;
    for (final incoming in contents.notes) {
      final local = repo.getRecord(incoming.id);
      if (local == null) {
        newNotes++;
      } else if (_same(local.toJson(), incoming.toJson())) {
        identicalNotes++;
      } else {
        conflictingNotes++;
        if (mergeNotes(local, incoming).conflictLoser != null) {
          potentialConflictCopies++;
        }
      }
    }

    var newFolders = 0;
    var identicalFolders = 0;
    var conflictingFolders = 0;
    for (final incoming in contents.folders) {
      final local = repo.getFolderRecord(incoming.id);
      if (local == null) {
        newFolders++;
      } else if (_same(local.toJson(), incoming.toJson())) {
        identicalFolders++;
      } else {
        conflictingFolders++;
      }
    }

    var newAttachments = 0;
    var identicalAttachments = 0;
    var conflictingAttachments = 0;
    for (final incoming in contents.attachments) {
      final local = repo.getAttachment(incoming.hash);
      if (local == null) {
        newAttachments++;
      } else if (_sameBytes(local, incoming.data)) {
        identicalAttachments++;
      } else {
        conflictingAttachments++;
      }
    }

    return NotesRestorePreview(
      format: exportFormat,
      version: contents.version,
      exportedAt: contents.exportedAt,
      noteCount: contents.notes.length,
      folderCount: contents.folders.length,
      attachmentCount: contents.attachments.length,
      newNotes: newNotes,
      identicalNotes: identicalNotes,
      conflictingNotes: conflictingNotes,
      potentialConflictCopies: potentialConflictCopies,
      newFolders: newFolders,
      identicalFolders: identicalFolders,
      conflictingFolders: conflictingFolders,
      newAttachments: newAttachments,
      identicalAttachments: identicalAttachments,
      conflictingAttachments: conflictingAttachments,
    );
  }

  /// Applies the complete export atomically. [onRecord] is a test hook called
  /// before each source note; throwing from it rolls back every record,
  /// folder, attachment and sequence change made by this restore.
  ///
  /// Identical rows are no-ops. A different row with the same id is merged
  /// using sync's version vectors, HLC clocks, per-field metadata registers
  /// and tombstone rules. Concurrent content edits keep the losing version as
  /// a deterministic conflict copy; a dominated import cannot overwrite
  /// newer local content. A tombstone follows those same rules and therefore
  /// cannot resurrect a locally newer purge.
  NotesRestoreReport apply(
    String text, {
    String? snapshotPath,
    void Function(int index)? onRecord,
  }) {
    final contents = parseExport(text);
    if (snapshotPath != null && repo.db.path != null) {
      repo.db.snapshotTo(snapshotPath);
    }

    return repo.db.transaction(() {
      final applier = RemoteApplier(repo, nowMs: _now);
      var notesCreated = 0;
      var notesUpdated = 0;
      var notesUnchanged = 0;
      var conflictCopies = 0;
      var foldersCreated = 0;
      var foldersUpdated = 0;
      var foldersUnchanged = 0;
      var attachmentsAdded = 0;
      var attachmentsAlreadyPresent = 0;

      // Folders precede notes so a record's folder id is present when both
      // are new. The schema still permits a note to refer to a deleted folder.
      for (final folder in contents.folders) {
        final result = applier.applyFolder(folder);
        switch (result.kind) {
          case ApplyKind.created:
            foldersCreated++;
          case ApplyKind.updated:
            foldersUpdated++;
          case ApplyKind.unchanged:
            foldersUnchanged++;
        }
      }

      for (final (index, note) in contents.notes.indexed) {
        onRecord?.call(index);
        final result = applier.applyNote(note);
        switch (result.kind) {
          case ApplyKind.created:
            notesCreated++;
          case ApplyKind.updated:
            notesUpdated++;
          case ApplyKind.unchanged:
            notesUnchanged++;
        }
        if (result.conflictCopyId != null) conflictCopies++;
      }

      // Note writes create empty attachment placeholders for referenced hashes.
      // Fill missing bytes after notes so the note-attachment index is ready.
      for (final attachment in contents.attachments) {
        final local = repo.getAttachment(attachment.hash);
        if (local == null) {
          repo.putAttachment(attachment.data, attachment.mime);
          attachmentsAdded++;
        } else if (_sameBytes(local, attachment.data)) {
          // The hash and bytes define attachment identity. Keep the existing
          // local MIME label when the same content is already stored.
          attachmentsAlreadyPresent++;
        } else {
          // A matching SHA-256 with different bytes signals a corrupt local
          // attachment or a hash collision. Keep local bytes and abort all rows.
          throw StateError(
            'Local attachment ${attachment.hash} has different bytes.',
          );
        }
      }

      return NotesRestoreReport(
        notesCreated: notesCreated,
        notesUpdated: notesUpdated,
        notesUnchanged: notesUnchanged,
        conflictCopies: conflictCopies,
        foldersCreated: foldersCreated,
        foldersUpdated: foldersUpdated,
        foldersUnchanged: foldersUnchanged,
        attachmentsAdded: attachmentsAdded,
        attachmentsAlreadyPresent: attachmentsAlreadyPresent,
      );
    });
  }
}

bool _same(Map<String, Object?> a, Map<String, Object?> b) =>
    jsonEncode(a) == jsonEncode(b);

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
