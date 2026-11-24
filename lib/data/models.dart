import '../core/hlc.dart';
import '../core/version_vector.dart';

/// What a library card shows. Carries no body, so lists stay cheap.
class NoteSummary {
  const NoteSummary({
    required this.id,
    required this.title,
    required this.preview,
    required this.createdAt,
    required this.updatedAt,
    required this.pinned,
    required this.archived,
    required this.folderId,
    required this.trashedAt,
    required this.tasksTotal,
    required this.tasksDone,
    required this.conflictOf,
    this.reviewEditsCount = 0,
  });

  final String id;
  final String title;
  final String preview;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool pinned;
  final bool archived;
  final String? folderId;
  final DateTime? trashedAt;
  final int tasksTotal;
  final int tasksDone;

  /// Set when this note is the kept losing side of a conflicting edit of the
  /// note with this id.
  final String? conflictOf;

  /// Live competing versions waiting to be reviewed on this note.
  final int reviewEditsCount;

  bool get isTrashed => trashedAt != null;
  bool get isConflictCopy => conflictOf != null;
}

/// A note with its body, as the editor needs it.
class Note extends NoteSummary {
  const Note({
    required super.id,
    required super.title,
    required super.preview,
    required super.createdAt,
    required super.updatedAt,
    required super.pinned,
    required super.archived,
    required super.folderId,
    required super.trashedAt,
    required super.tasksTotal,
    required super.tasksDone,
    required super.conflictOf,
    super.reviewEditsCount,
    required this.body,
    required this.contentVv,
  });

  /// Quill Delta as JSON (array of insert ops).
  final String body;

  /// Version of the content this object was read at. Pass it back when saving
  /// so a change made underneath (by sync) is detected instead of overwritten.
  final VersionVector contentVv;
}

class Folder {
  const Folder({required this.id, required this.name, required this.noteCount});

  final String id;
  final String name;

  /// Active (not archived, not trashed) notes in the folder.
  final int noteCount;
}

/// Which slice of the library a list shows.
enum NoteScope { active, archived, trash, conflicts }

class LibraryCounts {
  const LibraryCounts({
    required this.active,
    required this.unfiled,
    required this.archived,
    required this.trash,
    required this.conflicts,
  });

  final int active;
  final int unfiled;
  final int archived;
  final int trash;
  final int conflicts;
}

enum SaveOutcome {
  /// Content written.
  saved,

  /// Nothing differed from what is stored; nothing written.
  unchanged,

  /// The stored note had changed underneath. The editor's content was written
  /// and the other version was kept as a conflict copy.
  savedWithConflictCopy,
}

class SaveResult {
  const SaveResult(this.outcome, this.contentVv, {this.conflictCopyId});

  final SaveOutcome outcome;

  /// Version to pass to the next save.
  final VersionVector contentVv;
  final String? conflictCopyId;
}

/// A complete note row as stored and as exchanged between devices.
///
/// Content (title + body) is versioned by [contentVv]. Each metadata field is
/// an independent last-writer-wins register with its own clock.
class NoteRecord {
  const NoteRecord({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.contentHlc,
    required this.contentVv,
    required this.purged,
    required this.pinned,
    required this.pinnedHlc,
    required this.archived,
    required this.archivedHlc,
    required this.folderId,
    required this.folderHlc,
    required this.trashedAt,
    required this.trashedHlc,
    required this.conflictOf,
    required this.conflictHlc,
  });

  final String id;
  final String title;
  final String body;

  /// Milliseconds since the Unix epoch, UTC.
  final int createdAt;
  final int updatedAt;
  final Hlc contentHlc;
  final VersionVector contentVv;

  /// Deleted forever: content is gone, the row remains as a tombstone.
  final bool purged;
  final bool pinned;
  final Hlc pinnedHlc;
  final bool archived;
  final Hlc archivedHlc;
  final String? folderId;
  final Hlc folderHlc;
  final int? trashedAt;
  final Hlc trashedHlc;
  final String? conflictOf;
  final Hlc conflictHlc;

  NoteRecord copyWith({
    String? title,
    String? body,
    int? updatedAt,
    Hlc? contentHlc,
    VersionVector? contentVv,
    bool? purged,
    bool? pinned,
    Hlc? pinnedHlc,
    bool? archived,
    Hlc? archivedHlc,
    Object? folderId = _keep,
    Hlc? folderHlc,
    Object? trashedAt = _keep,
    Hlc? trashedHlc,
    Object? conflictOf = _keep,
    Hlc? conflictHlc,
  }) => NoteRecord(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    contentHlc: contentHlc ?? this.contentHlc,
    contentVv: contentVv ?? this.contentVv,
    purged: purged ?? this.purged,
    pinned: pinned ?? this.pinned,
    pinnedHlc: pinnedHlc ?? this.pinnedHlc,
    archived: archived ?? this.archived,
    archivedHlc: archivedHlc ?? this.archivedHlc,
    folderId: identical(folderId, _keep) ? this.folderId : folderId as String?,
    folderHlc: folderHlc ?? this.folderHlc,
    trashedAt: identical(trashedAt, _keep) ? this.trashedAt : trashedAt as int?,
    trashedHlc: trashedHlc ?? this.trashedHlc,
    conflictOf: identical(conflictOf, _keep)
        ? this.conflictOf
        : conflictOf as String?,
    conflictHlc: conflictHlc ?? this.conflictHlc,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'contentHlc': contentHlc.encode(),
    'contentVv': contentVv.counters,
    'purged': purged,
    'pinned': pinned,
    'pinnedHlc': pinnedHlc.encode(),
    'archived': archived,
    'archivedHlc': archivedHlc.encode(),
    'folderId': folderId,
    'folderHlc': folderHlc.encode(),
    'trashedAt': trashedAt,
    'trashedHlc': trashedHlc.encode(),
    'conflictOf': conflictOf,
    'conflictHlc': conflictHlc.encode(),
  };

  factory NoteRecord.fromJson(Map<String, Object?> j) => NoteRecord(
    id: j['id'] as String,
    title: j['title'] as String,
    body: j['body'] as String,
    createdAt: (j['createdAt'] as num).toInt(),
    updatedAt: (j['updatedAt'] as num).toInt(),
    contentHlc: Hlc.parse(j['contentHlc'] as String),
    contentVv: VersionVector({
      for (final e in (j['contentVv'] as Map).entries)
        e.key as String: (e.value as num).toInt(),
    }),
    purged: j['purged'] as bool,
    pinned: j['pinned'] as bool,
    pinnedHlc: Hlc.parse(j['pinnedHlc'] as String),
    archived: j['archived'] as bool,
    archivedHlc: Hlc.parse(j['archivedHlc'] as String),
    folderId: j['folderId'] as String?,
    folderHlc: Hlc.parse(j['folderHlc'] as String),
    trashedAt: (j['trashedAt'] as num?)?.toInt(),
    trashedHlc: Hlc.parse(j['trashedHlc'] as String),
    conflictOf: j['conflictOf'] as String?,
    conflictHlc: Hlc.parse(j['conflictHlc'] as String),
  );
}

const _keep = Object();

/// A folder row as stored and as exchanged between devices.
class FolderRecord {
  const FolderRecord({
    required this.id,
    required this.name,
    required this.nameHlc,
    required this.deleted,
    required this.deletedHlc,
    required this.createdAt,
  });

  final String id;
  final String name;
  final Hlc nameHlc;
  final bool deleted;
  final Hlc deletedHlc;
  final int createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'nameHlc': nameHlc.encode(),
    'deleted': deleted,
    'deletedHlc': deletedHlc.encode(),
    'createdAt': createdAt,
  };

  factory FolderRecord.fromJson(Map<String, Object?> j) => FolderRecord(
    id: j['id'] as String,
    name: j['name'] as String,
    nameHlc: Hlc.parse(j['nameHlc'] as String),
    deleted: j['deleted'] as bool,
    deletedHlc: Hlc.parse(j['deletedHlc'] as String),
    createdAt: (j['createdAt'] as num).toInt(),
  );
}
