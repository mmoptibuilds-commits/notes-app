import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/hlc.dart';
import '../core/ids.dart';
import '../core/version_vector.dart';
import '../doc/delta_text.dart';
import 'app_database.dart';
import 'editor_draft.dart';
import 'models.dart';

/// Prefix of an image embed source that points at a stored attachment:
/// `att:<sha256 hex>`.
const attachmentScheme = 'att:';

enum NoteSort { modified, created, title }

/// Which folder a listing is limited to.
class FolderFilter {
  const FolderFilter.all() : folderId = null, unfiled = false;
  const FolderFilter.unfiled() : folderId = null, unfiled = true;
  const FolderFilter.folder(String id) : folderId = id, unfiled = false;

  final String? folderId;
  final bool unfiled;
}

class SearchHit {
  const SearchHit(this.note, this.snippet);
  final NoteSummary note;

  /// Body text around the match. Matched terms are wrapped in
  /// [matchStart]/[matchEnd]. Empty when only the title matched.
  final String snippet;

  static const matchStart = '\u0002';
  static const matchEnd = '\u0003';
}

final Set<String> _activeEditorDraftLeases = {};
final Map<String, _EditorDraftLockGroup> _editorDraftLockGroups = {};

class _EditorDraftLockGroup {
  _EditorDraftLockGroup(this.file);
  final RandomAccessFile file;
  int leases = 0;
}

/// A process-wide and cross-process lock for one editor recovery draft.
/// Linux releases the process's advisory locks when any descriptor for the
/// same file closes, so locks in one directory share one descriptor until the
/// final lease is released.
class EditorDraftLease {
  EditorDraftLease._(this._leaseKey, this._groupKey, this._offset);

  final String _leaseKey;
  final String? _groupKey;
  final int _offset;
  var _released = false;

  void release() {
    if (_released) return;
    _released = true;
    try {
      final groupKey = _groupKey;
      if (groupKey != null) {
        final group = _editorDraftLockGroups[groupKey];
        if (group != null) {
          try {
            group.file.unlockSync(_offset, _offset + 1);
          } finally {
            group.leases--;
            if (group.leases == 0) {
              try {
                group.file.closeSync();
              } finally {
                _editorDraftLockGroups.remove(groupKey);
              }
            }
          }
        }
      }
    } finally {
      _activeEditorDraftLeases.remove(_leaseKey);
    }
  }
}

/// All reads and writes of notes, folders and attachments.
///
/// Every mutation runs in one transaction and stamps the sync metadata
/// (clocks, version vector, change sequence), so callers never touch those.
class NoteRepository {
  NoteRepository(this.db, {int Function()? nowMs})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase db;
  final int Function() _now;
  final _draftChanges = _RepositoryDraftNotifier();

  /// Fires after every committed change to notes, folders or attachments.
  Listenable get changes => db.changes;

  /// Notifies when the local recovery-draft list changes. Drafts do not enter
  /// the note sync queue.
  Listenable get draftChanges => _draftChanges;

  void dispose() => _draftChanges.dispose();

  /// Claims a draft for one live editor session. Returns null when another
  /// editor in this process or another Notes process already owns the row.
  /// Locks are released on process exit, so a crash does not strand a draft.
  EditorDraftLease? acquireEditorDraftLease(String id) {
    final databasePath = db.path;
    final canonicalDatabasePath = databasePath == null
        ? null
        : File(databasePath).resolveSymbolicLinksSync();
    final scope = canonicalDatabasePath == null
        ? 'memory:${identityHashCode(db)}'
        : p.normalize(canonicalDatabasePath);
    final leaseKey = '$scope|$id';
    if (!_activeEditorDraftLeases.add(leaseKey)) return null;
    if (canonicalDatabasePath == null) {
      return EditorDraftLease._(leaseKey, null, 0);
    }

    final lockPath = '$canonicalDatabasePath.draft-locks';
    if (FileSystemEntity.typeSync(lockPath, followLinks: false) ==
        FileSystemEntityType.link) {
      _activeEditorDraftLeases.remove(leaseKey);
      throw StateError('The editor draft lock is a symlink.');
    }
    final groupKey = p.normalize(p.absolute(lockPath));
    var group = _editorDraftLockGroups[groupKey];
    if (group == null) {
      try {
        group = _EditorDraftLockGroup(
          File(lockPath).openSync(mode: FileMode.append),
        );
        _editorDraftLockGroups[groupKey] = group;
      } on Object {
        _activeEditorDraftLeases.remove(leaseKey);
        rethrow;
      }
    }
    final offset = int.parse(sha256OfString(id).substring(0, 13), radix: 16);
    try {
      group.file.lockSync(FileLock.exclusive, offset, offset + 1);
      group.leases++;
      return EditorDraftLease._(leaseKey, groupKey, offset);
    } on FileSystemException {
      if (group.leases == 0) {
        group.file.closeSync();
        _editorDraftLockGroups.remove(groupKey);
      }
      _activeEditorDraftLeases.remove(leaseKey);
      return null;
    } on Object {
      if (group.leases == 0) {
        group.file.closeSync();
        _editorDraftLockGroups.remove(groupKey);
      }
      _activeEditorDraftLeases.remove(leaseKey);
      rethrow;
    }
  }

  String get _device => db.deviceId;

  // ------------------------------------------------------ editor recovery

  List<PendingEditorDraft> pendingEditorDrafts() => [
    for (final row in db.select(
      'SELECT id, note_id, folder_id, title, body, base_vv, updated_at '
      'FROM editor_drafts ORDER BY updated_at DESC, id',
    ))
      PendingEditorDraft(
        id: row['id'] as String,
        noteId: row['note_id'] as String?,
        folderId: row['folder_id'] as String?,
        title: row['title'] as String,
        body: row['body'] as String,
        baseVv: row['base_vv'] as String,
        updatedAt: row['updated_at'] as int,
      ),
  ];

  /// Reads the latest durable snapshot for one draft after its editor lease
  /// has been acquired. The recovery list may have rendered an older row
  /// before another editor finished writing it.
  PendingEditorDraft? pendingEditorDraft(String id) {
    final rows = db.select(
      'SELECT id, note_id, folder_id, title, body, base_vv, updated_at '
      'FROM editor_drafts WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return PendingEditorDraft(
      id: row['id'] as String,
      noteId: row['note_id'] as String?,
      folderId: row['folder_id'] as String?,
      title: row['title'] as String,
      body: row['body'] as String,
      baseVv: row['base_vv'] as String,
      updatedAt: row['updated_at'] as int,
    );
  }

  /// Persists an uncommitted editor snapshot in the encrypted database.
  void savePendingEditorDraft(PendingEditorDraft draft) {
    db.transaction(() {
      db.execute(
        'INSERT INTO editor_drafts '
        '(id, note_id, folder_id, title, body, base_vv, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET note_id = excluded.note_id, '
        'folder_id = excluded.folder_id, title = excluded.title, '
        'body = excluded.body, base_vv = excluded.base_vv, '
        'updated_at = excluded.updated_at',
        [
          draft.id,
          draft.noteId,
          draft.folderId,
          draft.title,
          draft.body,
          draft.baseVv,
          draft.updatedAt,
        ],
      );
    });
    _draftChanges.fire();
  }

  /// Saves a disposed editor's snapshot without reviving a draft that was
  /// already recovered or discarded. When [requireExisting] is true, the
  /// row is updated only if it is still pending. Otherwise the row is inserted
  /// only when absent; an existing row is already a durable copy.
  bool savePendingEditorDraftFromHandoff(
    PendingEditorDraft draft, {
    required bool requireExisting,
  }) {
    var changed = false;
    var pending = false;
    db.transaction(() {
      if (requireExisting) {
        db.execute(
          'UPDATE editor_drafts SET note_id = ?, folder_id = ?, title = ?, '
          'body = ?, base_vv = ?, updated_at = ? WHERE id = ?',
          [
            draft.noteId,
            draft.folderId,
            draft.title,
            draft.body,
            draft.baseVv,
            draft.updatedAt,
            draft.id,
          ],
        );
        changed =
            (db.select('SELECT changes() AS count').first['count'] as int) > 0;
      } else {
        db.execute(
          'INSERT OR IGNORE INTO editor_drafts '
          '(id, note_id, folder_id, title, body, base_vv, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            draft.id,
            draft.noteId,
            draft.folderId,
            draft.title,
            draft.body,
            draft.baseVv,
            draft.updatedAt,
          ],
        );
        changed =
            (db.select('SELECT changes() AS count').first['count'] as int) > 0;
      }
      pending = db.select('SELECT 1 FROM editor_drafts WHERE id = ?', [
        draft.id,
      ]).isNotEmpty;
    });
    if (changed) _draftChanges.fire();
    return pending;
  }

  /// Discards [id] after the user confirms that its unsaved text can be
  /// removed.
  bool discardPendingEditorDraft(String id) {
    var removed = false;
    db.transaction(() {
      db.execute('DELETE FROM editor_drafts WHERE id = ?', [id]);
      removed =
          (db.select('SELECT changes() AS count').first['count'] as int) > 0;
    });
    if (removed) _draftChanges.fire();
    return removed;
  }

  /// Saves editor content and clears its recovery row in one transaction.
  /// This prevents a successful write from being offered again after restart.
  EditorDraftWriteResult writeEditorContent({
    required String draftId,
    required String? noteId,
    required String title,
    required String body,
    required VersionVector base,
    bool requirePendingDraft = false,
    bool recoveringDraft = false,
    String? folderId,
  }) {
    decodeOps(body);
    var hadDraft = false;
    final result = db.transaction(() {
      hadDraft = db.select('SELECT 1 FROM editor_drafts WHERE id = ?', [
        draftId,
      ]).isNotEmpty;
      if (requirePendingDraft && !hadDraft) {
        throw const EditorDraftUnavailableException();
      }
      late final String savedId;
      late final VersionVector savedVv;
      String? conflictCopyId;
      if (noteId == null) {
        final note = createNote(title: title, body: body, folderId: folderId);
        savedId = note.id;
        savedVv = note.contentVv;
      } else {
        final current = getRecord(noteId);
        if (current == null ||
            current.purged ||
            (recoveringDraft && current.trashedAt != null)) {
          final note = createNote(title: title, body: body, folderId: folderId);
          savedId = note.id;
          savedVv = note.contentVv;
        } else {
          final saved = saveContent(
            noteId,
            title: title,
            body: body,
            base: base,
          );
          savedId = noteId;
          savedVv = saved.contentVv;
          conflictCopyId = saved.conflictCopyId;
        }
      }
      db.execute('DELETE FROM editor_drafts WHERE id = ?', [draftId]);
      return EditorDraftWriteResult(
        noteId: savedId,
        baseVv: savedVv.encode(),
        conflictCopyId: conflictCopyId,
      );
    });
    if (hadDraft) _draftChanges.fire();
    return result;
  }

  // ---------------------------------------------------------------- notes

  /// Creates a note. Callers create lazily, on the first real content, so the
  /// library never holds empty notes.
  Note createNote({
    String title = '',
    String body = emptyBodyJson,
    String? folderId,
    String? id,
  }) {
    return db.transaction(() {
      final hlc = db.clock.now();
      final now = _now();
      final record = NoteRecord(
        id: id ?? newId(),
        title: title,
        body: body,
        createdAt: now,
        updatedAt: now,
        contentHlc: hlc,
        contentVv: VersionVector({_device: 1}),
        purged: false,
        pinned: false,
        pinnedHlc: hlc,
        archived: false,
        archivedHlc: hlc,
        folderId: folderId,
        folderHlc: hlc,
        trashedAt: null,
        trashedHlc: hlc,
        conflictOf: null,
        conflictHlc: hlc,
      );
      writeRecord(record);
      return getNote(record.id)!;
    });
  }

  /// The note with its body, or null if it does not exist or was deleted
  /// forever.
  Note? getNote(String id) {
    final rows = db.select('$_noteSelect WHERE n.id = ? AND n.purged = 0', [
      id,
    ]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final s = _summary(r);
    return Note(
      id: s.id,
      title: s.title,
      preview: s.preview,
      createdAt: s.createdAt,
      updatedAt: s.updatedAt,
      pinned: s.pinned,
      archived: s.archived,
      folderId: s.folderId,
      trashedAt: s.trashedAt,
      tasksTotal: s.tasksTotal,
      tasksDone: s.tasksDone,
      conflictOf: s.conflictOf,
      reviewEditsCount: s.reviewEditsCount,
      body: r['body'] as String,
      contentVv: VersionVector.decode(r['content_vv'] as String),
    );
  }

  /// Live conflict copies for [noteId], including when the main note is in
  /// Trash or has been purged. Purged copies are excluded.
  List<Note> conflictCopiesOf(String noteId) {
    final rows = db.select(
      '$_noteSelect WHERE n.conflict_of = ? AND n.purged = 0 ORDER BY n.created_at, n.id',
      [noteId],
    );
    return [for (final r in rows) _note(r)];
  }

  /// Adopts a competing version and preserves the displaced main version as
  /// a conflict copy. Both writes commit together.
  void useConflictCopy(String noteId, String copyId) {
    db.transaction(() {
      final main = getRecord(noteId);
      final copy = getRecord(copyId);
      if (main == null ||
          main.purged ||
          copy == null ||
          copy.purged ||
          copy.conflictOf != noteId) {
        throw StateError('Review version is no longer available');
      }
      _insertConflictCopy(main);
      final hlc = db.clock.now();
      writeRecord(
        main.copyWith(
          title: copy.title,
          body: copy.body,
          updatedAt: _now(),
          purged: false,
          contentHlc: hlc,
          contentVv: main.contentVv.merge(copy.contentVv).increment(_device),
        ),
      );
      writeRecord(
        copy.copyWith(
          title: '',
          body: emptyBodyJson,
          purged: true,
          contentHlc: hlc,
          contentVv: copy.contentVv.increment(_device),
        ),
      );
    });
  }

  /// Writes the editor's content.
  ///
  /// [base] is the version the editor last loaded or saved. If the stored
  /// note has moved on since (sync wrote underneath), the stored version is
  /// kept as a conflict copy and the editor's content becomes the note:
  /// neither side is dropped.
  SaveResult saveContent(
    String id, {
    required String title,
    required String body,
    required VersionVector base,
  }) {
    decodeOps(body); // Reject a malformed body before touching the database.
    return db.transaction(() {
      final current = getRecord(id);
      if (current == null) throw StateError('No note $id');
      if (!current.purged && current.title == title && current.body == body) {
        return SaveResult(SaveOutcome.unchanged, current.contentVv);
      }
      final hlc = db.clock.now();
      String? copyId;
      if (current.contentVv != base && !current.purged) {
        copyId = _insertConflictCopy(current);
      }
      final vv = current.contentVv.merge(base).increment(_device);
      writeRecord(
        current.copyWith(
          title: title,
          body: body,
          purged: false,
          updatedAt: _now(),
          contentHlc: hlc,
          contentVv: vv,
        ),
      );
      return SaveResult(
        copyId == null ? SaveOutcome.saved : SaveOutcome.savedWithConflictCopy,
        vv,
        conflictCopyId: copyId,
      );
    });
  }

  List<NoteSummary> listNotes({
    NoteScope scope = NoteScope.active,
    FolderFilter folder = const FolderFilter.all(),
    NoteSort sort = NoteSort.modified,
  }) {
    final where = StringBuffer(_scopeWhere(scope));
    final args = <Object?>[];
    if (folder.unfiled) {
      where.write(' AND f.id IS NULL');
    } else if (folder.folderId != null) {
      where.write(' AND f.id = ?');
      args.add(folder.folderId);
    }
    final order = switch (sort) {
      NoteSort.modified => 'n.updated_at DESC',
      NoteSort.created => 'n.created_at DESC',
      NoteSort.title => "CASE WHEN n.title = '' THEN n.preview ELSE n.title END COLLATE NOCASE ASC",
    };
    final pinFirst = scope == NoteScope.active ? 'n.pinned DESC, ' : '';
    final rows = db.select(
      '$_summarySelect WHERE $where ORDER BY $pinFirst$order, n.pk DESC',
      args,
    );
    return [for (final r in rows) _summary(r)];
  }

  /// Full-text search over title and body. Every word must match; the last
  /// word matches as a prefix so results appear while typing.
  List<SearchHit> search(
    String query, {
    NoteScope scope = NoteScope.active,
    bool includeArchived = true,
    int limit = 200,
  }) {
    final match = ftsQuery(query);
    if (match == null) return const [];
    var where = _scopeWhere(scope);
    if (scope == NoteScope.active && includeArchived) {
      where = 'n.purged = 0 AND n.trashed_at IS NULL AND n.conflict_of IS NULL';
    }
    final rows = db.select(
      '''
      SELECT ${_summaryColumns.join(', ')}, n.pk AS pk
      FROM notes_fts
      JOIN notes n ON n.pk = notes_fts.rowid
      $_summaryJoins
      WHERE notes_fts MATCH ? AND $where
      ORDER BY bm25(notes_fts, 6.0, 1.0), n.updated_at DESC
      LIMIT ?
      ''',
      [match, limit],
    );
    final terms = [
      for (final w in query.split(RegExp(r'\s+')))
        if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(w))
          w
              .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')
              .toLowerCase(),
    ].where((w) => w.isNotEmpty).toList();
    var n = 0;
    return [
      for (final r in rows)
        SearchHit(
          _summary(r),
          n++ < _snippetRows ? _snippet(r['pk'] as int, terms) : '',
        ),
    ];
  }

  /// Snippets are built for the first results only.
  static const _snippetRows = 60;

  /// A short excerpt around the first match, with matches marked.
  ///
  /// Built here, not with SQLite's `snippet()`, because that re-reads the
  /// whole document: one hit inside a 1 MB note took over two seconds. This
  /// looks only at a small window. Accent-insensitive matches (which the
  /// index finds) may yield no excerpt; the card then shows its normal preview.
  String _snippet(int pk, List<String> terms) {
    const before = 40;
    const width = 150;
    for (final term in terms) {
      final row = db.select(
        'SELECT instr(lower(plain_text), ?) AS p FROM notes WHERE pk = ?',
        [term, pk],
      ).first;
      final pos = row['p'] as int;
      if (pos <= 0) continue;
      final start = pos > before ? pos - before : 1;
      var text =
          db.select(
                'SELECT substr(plain_text, ?, ?) AS t FROM notes WHERE pk = ?',
                [start, width, pk],
              ).first['t']
              as String;
      text = text.replaceAll(RegExp(r'\s+'), ' ');
      // Drop a half word at the left edge and mark the cut.
      if (start > 1) {
        final sp = text.indexOf(' ');
        if (sp >= 0 && sp < 15) text = text.substring(sp + 1);
        text = '…$text';
      }
      final re = RegExp(
        terms.map(RegExp.escape).join('|'),
        caseSensitive: false,
        unicode: true,
      );
      text = text.replaceAllMapped(
        re,
        (m) => '${SearchHit.matchStart}${m[0]}${SearchHit.matchEnd}',
      );
      return '$text…';
    }
    return '';
  }

  /// Turns free text into an FTS5 query, or null if it has no searchable
  /// characters. Input is always treated as literal words, never as FTS syntax.
  static String? ftsQuery(String input) {
    final words = input
        .split(RegExp(r'\s+'))
        .where((w) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(w))
        .toList();
    if (words.isEmpty) return null;
    String quote(String w) => '"${w.replaceAll('"', '""')}"';
    return [
      for (var i = 0; i < words.length; i++)
        i == words.length - 1 ? '${quote(words[i])}*' : quote(words[i]),
    ].join(' ');
  }

  void setPinned(Iterable<String> ids, bool pinned) =>
      _updateEach(ids, (r, hlc) => r.copyWith(pinned: pinned, pinnedHlc: hlc));

  void setArchived(Iterable<String> ids, bool archived) => _updateEach(
    ids,
    (r, hlc) => r.copyWith(archived: archived, archivedHlc: hlc),
  );

  /// Moves notes to [folderId], or out of any folder when null.
  void moveToFolder(Iterable<String> ids, String? folderId) => _updateEach(
    ids,
    (r, hlc) => r.copyWith(folderId: folderId, folderHlc: hlc),
  );

  /// Moves notes to Trash. They stay there until restored or deleted forever.
  void trash(Iterable<String> ids) {
    final now = _now();
    _updateEach(ids, (r, hlc) => r.copyWith(trashedAt: now, trashedHlc: hlc));
  }

  void restore(Iterable<String> ids) => _updateEach(
    ids,
    (r, hlc) => r.copyWith(trashedAt: null, trashedHlc: hlc),
  );

  /// Marks a conflict copy as reviewed: it becomes an ordinary note.
  void keepConflictCopy(Iterable<String> ids) => _updateEach(
    ids,
    (r, hlc) => r.copyWith(conflictOf: null, conflictHlc: hlc),
  );

  /// Deletes notes forever. Content is erased; a tombstone remains so the
  /// deletion reaches other devices.
  void purge(Iterable<String> ids) => _updateEach(
    ids,
    (r, hlc) => r.copyWith(
      title: '',
      body: emptyBodyJson,
      purged: true,
      contentHlc: hlc,
      contentVv: r.contentVv.increment(_device),
    ),
  );

  /// Deletes forever everything currently in Trash. Returns how many.
  int emptyTrash() {
    return db.transaction(() {
      final ids = [
        for (final r in db.select(
          'SELECT id FROM notes WHERE purged = 0 AND trashed_at IS NOT NULL',
        ))
          r['id'] as String,
      ];
      purge(ids);
      return ids.length;
    });
  }

  LibraryCounts counts() {
    final r = db.select('''
      SELECT
        sum(n.trashed_at IS NULL AND n.archived = 0 AND n.conflict_of IS NULL) AS active,
        sum(n.trashed_at IS NULL AND n.archived = 0 AND n.conflict_of IS NULL AND f.id IS NULL) AS unfiled,
        sum(n.trashed_at IS NULL AND n.archived = 1 AND n.conflict_of IS NULL) AS archived,
        sum(n.trashed_at IS NOT NULL) AS trash,
        sum(n.trashed_at IS NULL AND n.conflict_of IS NOT NULL) AS conflicts
      FROM notes n
      LEFT JOIN folders f ON f.id = n.folder_id AND f.deleted = 0
      WHERE n.purged = 0
    ''').first;
    int v(String k) => (r[k] as int?) ?? 0;
    return LibraryCounts(
      active: v('active'),
      unfiled: v('unfiled'),
      archived: v('archived'),
      trash: v('trash'),
      conflicts: v('conflicts'),
    );
  }

  // -------------------------------------------------------------- folders

  List<Folder> listFolders() {
    final rows = db.select('''
      SELECT f.id, f.name,
        (SELECT count(*) FROM notes n
          WHERE n.folder_id = f.id AND n.purged = 0
            AND n.trashed_at IS NULL AND n.archived = 0
            AND n.conflict_of IS NULL) AS cnt
      FROM folders f
      WHERE f.deleted = 0
      ORDER BY f.name COLLATE NOCASE, f.id
    ''');
    return [
      for (final r in rows)
        Folder(
          id: r['id'] as String,
          name: r['name'] as String,
          noteCount: r['cnt'] as int,
        ),
    ];
  }

  /// Creates a folder, or returns the existing one with the same name
  /// (ignoring case and surrounding space).
  Folder createFolder(String name) {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
    return db.transaction(() {
      final existing = db.select(
        'SELECT id FROM folders WHERE deleted = 0 AND name = ? COLLATE NOCASE',
        [clean],
      );
      if (existing.isNotEmpty) {
        final id = existing.first['id'] as String;
        return listFolders().firstWhere((f) => f.id == id);
      }
      final hlc = db.clock.now();
      // Two devices that create the same folder name independently get the
      // same id, so pairing them does not leave a duplicate. A name that was
      // used before (and renamed or deleted since) gets a fresh id instead.
      final byName = derivedId('folder', [clean.toLowerCase()]);
      final record = FolderRecord(
        id: getFolderRecord(byName) == null ? byName : newId(),
        name: clean,
        nameHlc: hlc,
        deleted: false,
        deletedHlc: hlc,
        createdAt: _now(),
      );
      writeFolderRecord(record);
      return Folder(id: record.id, name: clean, noteCount: 0);
    });
  }

  void renameFolder(String id, String name) {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
    db.transaction(() {
      final r = getFolderRecord(id);
      if (r == null) throw StateError('No folder $id');
      writeFolderRecord(
        FolderRecord(
          id: r.id,
          name: clean,
          nameHlc: db.clock.now(),
          deleted: r.deleted,
          deletedHlc: r.deletedHlc,
          createdAt: r.createdAt,
        ),
      );
    });
  }

  /// Removes a folder. Its notes are kept and become unfiled.
  void deleteFolder(String id) {
    db.transaction(() {
      final r = getFolderRecord(id);
      if (r == null) return;
      writeFolderRecord(
        FolderRecord(
          id: r.id,
          name: r.name,
          nameHlc: r.nameHlc,
          deleted: true,
          deletedHlc: db.clock.now(),
          createdAt: r.createdAt,
        ),
      );
    });
  }

  // ---------------------------------------------------------- attachments

  /// Stores [bytes] and returns the source string to put in an image embed.
  String putAttachment(Uint8List bytes, String mime) {
    final hash = sha256Hex(bytes);
    db.transaction(() {
      db.execute(
        '''
        INSERT INTO attachments(hash, mime, size, data, created_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(hash) DO UPDATE SET data = excluded.data,
          mime = excluded.mime, size = excluded.size
          WHERE attachments.data IS NULL
        ''',
        [hash, mime, bytes.length, bytes, _now()],
      );
      db.markChanged();
    });
    return '$attachmentScheme$hash';
  }

  /// Bytes for an `att:<hash>` source or bare hash; null if not (yet) present.
  Uint8List? getAttachment(String source) {
    final hash = source.startsWith(attachmentScheme)
        ? source.substring(attachmentScheme.length)
        : source;
    final rows = db.select('SELECT data FROM attachments WHERE hash = ?', [
      hash,
    ]);
    return rows.isEmpty ? null : rows.first['data'] as Uint8List?;
  }

  /// Hashes referenced by some note but whose bytes are not stored here.
  List<String> missingAttachments() => [
    for (final r in db.select(
      'SELECT hash FROM attachments WHERE data IS NULL ORDER BY hash',
    ))
      r['hash'] as String,
  ];

  /// Removes attachments no note refers to any more. Returns how many.
  int collectUnusedAttachments() {
    return db.transaction(() {
      db.execute(
        'DELETE FROM attachments WHERE hash NOT IN '
        '(SELECT hash FROM note_attachments)',
      );
      return db.raw.updatedRows;
    });
  }

  // ------------------------------------------------- records (sync/import)

  /// The stored row, including deleted-forever tombstones.
  NoteRecord? getRecord(String id) {
    final rows = db.select('SELECT * FROM notes WHERE id = ?', [id]);
    return rows.isEmpty ? null : _record(rows.first);
  }

  FolderRecord? getFolderRecord(String id) {
    final rows = db.select('SELECT * FROM folders WHERE id = ?', [id]);
    return rows.isEmpty ? null : _folderRecord(rows.first);
  }

  /// Note rows changed locally after sequence [seq], oldest change first.
  List<(int seq, NoteRecord record)> noteRecordsSince(int seq, {int? limit}) =>
      [
        for (final r in db.select(
          'SELECT * FROM notes WHERE local_seq > ? ORDER BY local_seq'
          '${limit == null ? '' : ' LIMIT $limit'}',
          [seq],
        ))
          (r['local_seq'] as int, _record(r)),
      ];

  List<(int seq, FolderRecord record)> folderRecordsSince(int seq) => [
    for (final r in db.select(
      'SELECT * FROM folders WHERE local_seq > ? ORDER BY local_seq',
      [seq],
    ))
      (r['local_seq'] as int, _folderRecord(r)),
  ];

  /// A bounded, sequence-ordered page across both record kinds.
  List<({int seq, String kind, Object record})> cloudRecordsSince(
    int seq, {
    int limit = 100,
  }) {
    if (limit <= 0) return const [];
    final page = db.select(
      '''SELECT local_seq,kind,id FROM (
        SELECT local_seq,'note' AS kind,id FROM notes WHERE local_seq > ?
        UNION ALL
        SELECT local_seq,'folder' AS kind,id FROM folders WHERE local_seq > ?
      ) ORDER BY local_seq LIMIT ?''',
      [seq, seq, limit],
    );
    return [
      for (final item in page)
        if (item['kind'] == 'note')
          (
            seq: item['local_seq'] as int,
            kind: 'note',
            record: _record(
              db.select('SELECT * FROM notes WHERE id=?', [item['id']]).single,
            ),
          )
        else
          (
            seq: item['local_seq'] as int,
            kind: 'folder',
            record: _folderRecord(
              db.select('SELECT * FROM folders WHERE id=?', [
                item['id'],
              ]).single,
            ),
          ),
    ];
  }

  Uint8List? attachmentBytes(String hash) => getAttachment(hash);

  /// Stores a downloaded attachment after the caller has verified its hash.
  void storeCloudAttachment(String hash, String mime, Uint8List bytes) {
    if (sha256Hex(bytes) != hash) {
      throw const FormatException('Attachment hash mismatch.');
    }
    db.transaction(() {
      db.execute(
        '''INSERT INTO attachments(hash,mime,size,data,created_at) VALUES(?,?,?,?,?)
        ON CONFLICT(hash) DO UPDATE SET mime=excluded.mime,size=excluded.size,data=excluded.data''',
        [hash, mime, bytes.length, bytes, _now()],
      );
      db.markChanged();
    });
  }

  /// Inserts or replaces a note row exactly as given (after normalising it),
  /// recomputes everything derived from the body, and queues it for sync.
  ///
  /// Low level: callers are responsible for the clocks and version vector in
  /// [record]. Must run inside a transaction.
  void writeRecord(NoteRecord record) {
    final r = normalise(record);
    final digest = r.purged ? null : digestBody(r.body);
    db.execute(
      '''
      INSERT INTO notes(
        id, title, body, plain_text, preview, tasks_total, tasks_done,
        created_at, updated_at, content_hlc, content_vv, purged,
        pinned, pinned_hlc, archived, archived_hlc, folder_id, folder_hlc,
        trashed_at, trashed_hlc, conflict_of, conflict_hlc, local_seq)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        title = excluded.title, body = excluded.body,
        plain_text = excluded.plain_text, preview = excluded.preview,
        tasks_total = excluded.tasks_total, tasks_done = excluded.tasks_done,
        created_at = excluded.created_at, updated_at = excluded.updated_at,
        content_hlc = excluded.content_hlc, content_vv = excluded.content_vv,
        purged = excluded.purged,
        pinned = excluded.pinned, pinned_hlc = excluded.pinned_hlc,
        archived = excluded.archived, archived_hlc = excluded.archived_hlc,
        folder_id = excluded.folder_id, folder_hlc = excluded.folder_hlc,
        trashed_at = excluded.trashed_at, trashed_hlc = excluded.trashed_hlc,
        conflict_of = excluded.conflict_of, conflict_hlc = excluded.conflict_hlc,
        local_seq = excluded.local_seq
      ''',
      [
        r.id,
        r.title,
        r.body,
        digest?.plainText ?? '',
        digest?.preview ?? '',
        digest?.tasksTotal ?? 0,
        digest?.tasksDone ?? 0,
        r.createdAt,
        r.updatedAt,
        r.contentHlc.encode(),
        r.contentVv.encode(),
        r.purged ? 1 : 0,
        r.pinned ? 1 : 0,
        r.pinnedHlc.encode(),
        r.archived ? 1 : 0,
        r.archivedHlc.encode(),
        r.folderId,
        r.folderHlc.encode(),
        r.trashedAt,
        r.trashedHlc.encode(),
        r.conflictOf,
        r.conflictHlc.encode(),
        db.nextSeq(),
      ],
    );
    db.execute('DELETE FROM note_attachments WHERE note_id = ?', [r.id]);
    for (final source in digest?.imageSources ?? const <String>[]) {
      if (!source.startsWith(attachmentScheme)) continue;
      final hash = source.substring(attachmentScheme.length);
      db.execute(
        'INSERT OR IGNORE INTO note_attachments(note_id, hash) VALUES (?, ?)',
        [r.id, hash],
      );
      db.execute(
        'INSERT OR IGNORE INTO attachments(hash, mime, size, data, created_at) '
        "VALUES (?, '', 0, NULL, ?)",
        [hash, _now()],
      );
    }
    db.markChanged();
  }

  void writeFolderRecord(FolderRecord r) {
    db.execute(
      '''
      INSERT INTO folders(id, name, name_hlc, deleted, deleted_hlc, created_at, local_seq)
      VALUES (?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name, name_hlc = excluded.name_hlc,
        deleted = excluded.deleted, deleted_hlc = excluded.deleted_hlc,
        created_at = excluded.created_at, local_seq = excluded.local_seq
      ''',
      [
        r.id,
        r.name,
        r.nameHlc.encode(),
        r.deleted ? 1 : 0,
        r.deletedHlc.encode(),
        r.createdAt,
        db.nextSeq(),
      ],
    );
    db.markChanged();
  }

  /// Applies the rules that hold for every stored note, however it was
  /// produced (local edit, merge, import):
  ///  * a tombstone carries no content;
  ///  * content edited after the note was trashed brings it back from Trash.
  static NoteRecord normalise(NoteRecord r) {
    var out = r;
    if (out.purged && (out.title.isNotEmpty || out.body != emptyBodyJson)) {
      out = out.copyWith(title: '', body: emptyBodyJson);
    }
    if (out.trashedAt != null &&
        !out.purged &&
        out.contentHlc > out.trashedHlc) {
      out = out.copyWith(trashedAt: null);
    }
    return out;
  }

  /// The record a conflict keeps for the version that did not become the
  /// note. Depends only on [loser], so every device that sees the same
  /// conflict builds the identical copy.
  static NoteRecord conflictCopyOf(NoteRecord loser) {
    final id = derivedId('conflict', [loser.id, loser.contentVv.encode()]);
    final hlc = loser.contentHlc;
    return NoteRecord(
      id: id,
      title: loser.title,
      body: loser.body,
      createdAt: loser.createdAt,
      updatedAt: loser.updatedAt,
      contentHlc: hlc,
      contentVv: VersionVector({'conflict:${id.substring(0, 8)}': 1}),
      purged: false,
      pinned: false,
      pinnedHlc: hlc,
      archived: false,
      archivedHlc: hlc,
      folderId: loser.folderId,
      folderHlc: hlc,
      trashedAt: null,
      trashedHlc: hlc,
      conflictOf: loser.id,
      conflictHlc: hlc,
    );
  }

  /// Stores the conflict copy of [loser] unless that exact copy already
  /// exists (in any state, including deleted). Returns its id.
  String insertConflictCopyIfAbsent(NoteRecord loser) =>
      _insertConflictCopy(loser);

  String _insertConflictCopy(NoteRecord loser) {
    final copy = conflictCopyOf(loser);
    if (getRecord(copy.id) == null) writeRecord(copy);
    return copy.id;
  }

  // -------------------------------------------------------------- private

  void _updateEach(
    Iterable<String> ids,
    NoteRecord Function(NoteRecord record, Hlc hlc) change,
  ) {
    final list = ids.toList();
    if (list.isEmpty) return;
    db.transaction(() {
      final hlc = db.clock.now();
      for (final id in list) {
        final r = getRecord(id);
        if (r == null || r.purged) continue;
        writeRecord(change(r, hlc));
      }
    });
  }

  static String _scopeWhere(NoteScope scope) => switch (scope) {
    NoteScope.active => 'n.purged = 0 AND n.trashed_at IS NULL AND n.archived = 0 AND n.conflict_of IS NULL',
    NoteScope.archived => 'n.purged = 0 AND n.trashed_at IS NULL AND n.archived = 1 AND n.conflict_of IS NULL',
    NoteScope.trash => 'n.purged = 0 AND n.trashed_at IS NOT NULL',
    NoteScope.conflicts =>
      'n.purged = 0 AND n.trashed_at IS NULL AND n.conflict_of IS NOT NULL',
  };

  static const _summaryColumns = [
    'n.id',
    'n.title',
    'n.preview',
    'n.created_at',
    'n.updated_at',
    'n.pinned',
    'n.archived',
    'f.id AS live_folder_id',
    'n.trashed_at',
    'n.tasks_total',
    'n.tasks_done',
    'n.conflict_of',
    'coalesce(review_copies.copy_count, 0) AS review_edits_count',
  ];

  static const _summaryJoins = '''
    LEFT JOIN folders f ON f.id = n.folder_id AND f.deleted = 0
    LEFT JOIN (
      SELECT conflict_of, count(*) AS copy_count
      FROM notes
      WHERE purged = 0 AND conflict_of IS NOT NULL
      GROUP BY conflict_of
    ) review_copies ON review_copies.conflict_of = n.id
  ''';

  static final _summarySelect =
      'SELECT ${_summaryColumns.join(', ')} FROM notes n $_summaryJoins';

  static final _noteSelect =
      'SELECT ${_summaryColumns.join(', ')}, n.body, n.content_vv FROM notes n $_summaryJoins';

  static NoteSummary _summary(Row r) => NoteSummary(
    id: r['id'] as String,
    title: r['title'] as String,
    preview: r['preview'] as String,
    createdAt: _date(r['created_at'] as int),
    updatedAt: _date(r['updated_at'] as int),
    pinned: r['pinned'] == 1,
    archived: r['archived'] == 1,
    folderId: r['live_folder_id'] as String?,
    trashedAt: r['trashed_at'] == null ? null : _date(r['trashed_at'] as int),
    tasksTotal: r['tasks_total'] as int,
    tasksDone: r['tasks_done'] as int,
    conflictOf: r['conflict_of'] as String?,
    reviewEditsCount: r['review_edits_count'] as int? ?? 0,
  );

  static Note _note(Row r) {
    final s = _summary(r);
    return Note(
      id: s.id,
      title: s.title,
      preview: s.preview,
      createdAt: s.createdAt,
      updatedAt: s.updatedAt,
      pinned: s.pinned,
      archived: s.archived,
      folderId: s.folderId,
      trashedAt: s.trashedAt,
      tasksTotal: s.tasksTotal,
      tasksDone: s.tasksDone,
      conflictOf: s.conflictOf,
      reviewEditsCount: s.reviewEditsCount,
      body: r['body'] as String,
      contentVv: VersionVector.decode(r['content_vv'] as String),
    );
  }

  static DateTime _date(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  static NoteRecord _record(Row r) => NoteRecord(
    id: r['id'] as String,
    title: r['title'] as String,
    body: r['body'] as String,
    createdAt: r['created_at'] as int,
    updatedAt: r['updated_at'] as int,
    contentHlc: Hlc.parse(r['content_hlc'] as String),
    contentVv: VersionVector.decode(r['content_vv'] as String),
    purged: r['purged'] == 1,
    pinned: r['pinned'] == 1,
    pinnedHlc: Hlc.parse(r['pinned_hlc'] as String),
    archived: r['archived'] == 1,
    archivedHlc: Hlc.parse(r['archived_hlc'] as String),
    folderId: r['folder_id'] as String?,
    folderHlc: Hlc.parse(r['folder_hlc'] as String),
    trashedAt: r['trashed_at'] as int?,
    trashedHlc: Hlc.parse(r['trashed_hlc'] as String),
    conflictOf: r['conflict_of'] as String?,
    conflictHlc: Hlc.parse(r['conflict_hlc'] as String),
  );

  static FolderRecord _folderRecord(Row r) => FolderRecord(
    id: r['id'] as String,
    name: r['name'] as String,
    nameHlc: Hlc.parse(r['name_hlc'] as String),
    deleted: r['deleted'] == 1,
    deletedHlc: Hlc.parse(r['deleted_hlc'] as String),
    createdAt: r['created_at'] as int,
  );
}

class _RepositoryDraftNotifier extends ChangeNotifier {
  void fire() => notifyListeners();
}
