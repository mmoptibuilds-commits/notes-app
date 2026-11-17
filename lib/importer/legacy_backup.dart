import 'dart:convert';
import 'dart:typed_data';

import '../core/hlc.dart';
import '../core/ids.dart';
import '../core/version_vector.dart';
import '../data/models.dart';
import '../data/note_repository.dart';
import '../doc/delta_text.dart';

/// The input is not a legacy Notebook backup this importer can read.
class LegacyBackupFormatException implements Exception {
  LegacyBackupFormatException(this.message);
  final String message;
  @override
  String toString() => 'LegacyBackupFormatException: $message';
}

/// Highest legacy `version` this importer has been checked against.
const legacyKnownVersion = 11;

/// Legacy `color` value meaning "no colour chosen".
const _legacyDefaultColor = 0xFF252529;

const _legacyNode = 'legacy';

/// Tables of the legacy export that belong to the notes feature.
const _notesTables = {'notes', 'tags', 'noteTags', 'deletedNotes'};

/// What happened to one source note.
abstract final class ImportAction {
  static const created = 'created';
  static const unchanged = 'unchanged';
  static const updated = 'updated';
  static const skippedOlder = 'skipped_older';
  static const conflictCopy = 'conflict_copy';
  static const restored = 'restored';
  static const skippedDeleted = 'skipped_deleted';
  static const all = [
    created,
    unchanged,
    updated,
    skippedOlder,
    conflictCopy,
    restored,
    skippedDeleted,
  ];
}

class InvalidRow {
  const InvalidRow(this.index, this.reason);
  final int index;
  final String reason;
  Map<String, Object?> toJson() => {'index': index, 'reason': reason};
}

/// Outcome of [LegacyBackupImporter.inspect] / [LegacyBackupImporter.import].
/// Never contains note titles, text or image paths.
class ImportReport {
  ImportReport({
    this.batchId = '',
    this.dryRun = false,
    this.sourceName,
    this.formatVersion,
    this.sourceNotes = 0,
  });

  String batchId;

  /// True for [LegacyBackupImporter.inspect]: nothing was written.
  bool dryRun;
  String? sourceName;
  int? formatVersion;
  int sourceNotes;
  final Map<String, int> bySourceState = {
    'active': 0,
    'archived': 0,
    'deleted': 0,
  };
  final Map<String, int> actions = {for (final a in ImportAction.all) a: 0};
  int foldersCreated = 0;

  /// Ids of folders this batch created (or revived); rollback removes them if
  /// they end up empty.
  final List<String> createdFolderIds = [];
  int plainTextConverted = 0;
  final List<InvalidRow> invalidRows = [];
  int missingImages = 0;
  final List<String> missingImageNoteIds = [];

  /// Notes that carried a field the new app has no place for.
  final Map<String, int> unsupportedFields = {
    'color': 0,
    'tags': 0,
    'reminderAt': 0,
    'isLocked': 0,
    'imagePath': 0,
    'previewText': 0,
  };
  final Map<String, int> outOfScopeTables = {};
  int tagRows = 0;
  int noteTagRows = 0;
  int tombstones = 0;
  final List<String> warnings = [];

  Map<String, Object?> toJson() => {
    'batchId': batchId,
    'dryRun': dryRun,
    'sourceName': sourceName,
    'formatVersion': formatVersion,
    'sourceNotes': sourceNotes,
    'bySourceState': bySourceState,
    'actions': actions,
    'foldersCreated': foldersCreated,
    'createdFolderIds': createdFolderIds,
    'plainTextConverted': plainTextConverted,
    'invalidRows': [for (final r in invalidRows) r.toJson()],
    'missingImages': missingImages,
    'missingImageNoteIds': missingImageNoteIds,
    'unsupportedFields': unsupportedFields,
    'outOfScopeTables': outOfScopeTables,
    'tagRows': tagRows,
    'noteTagRows': noteTagRows,
    'tombstones': tombstones,
    'warnings': warnings,
  };

  factory ImportReport.fromJson(Map<String, Object?> j) {
    Map<String, int> ints(Object? v) => {
      for (final e in ((v as Map?) ?? const {}).entries)
        e.key as String: (e.value as num).toInt(),
    };
    final r = ImportReport(
      batchId: (j['batchId'] as String?) ?? '',
      dryRun: j['dryRun'] == true,
      sourceName: j['sourceName'] as String?,
      formatVersion: (j['formatVersion'] as num?)?.toInt(),
      sourceNotes: (j['sourceNotes'] as num?)?.toInt() ?? 0,
    );
    r.bySourceState.addAll(ints(j['bySourceState']));
    r.actions.addAll(ints(j['actions']));
    r.foldersCreated = (j['foldersCreated'] as num?)?.toInt() ?? 0;
    r.createdFolderIds.addAll(
      ((j['createdFolderIds'] as List?) ?? const []).cast<String>(),
    );
    r.plainTextConverted = (j['plainTextConverted'] as num?)?.toInt() ?? 0;
    for (final e in (j['invalidRows'] as List?) ?? const []) {
      final m = e as Map;
      r.invalidRows.add(
        InvalidRow((m['index'] as num).toInt(), m['reason'] as String),
      );
    }
    r.missingImages = (j['missingImages'] as num?)?.toInt() ?? 0;
    r.missingImageNoteIds.addAll(
      ((j['missingImageNoteIds'] as List?) ?? const []).cast<String>(),
    );
    r.unsupportedFields.addAll(ints(j['unsupportedFields']));
    r.outOfScopeTables.addAll(ints(j['outOfScopeTables']));
    r.tagRows = (j['tagRows'] as num?)?.toInt() ?? 0;
    r.noteTagRows = (j['noteTagRows'] as num?)?.toInt() ?? 0;
    r.tombstones = (j['tombstones'] as num?)?.toInt() ?? 0;
    r.warnings.addAll(((j['warnings'] as List?) ?? const []).cast<String>());
    return r;
  }

  /// A few lines for a dialog or a log. No note content.
  String summary() {
    final a = actions;
    final b = StringBuffer()
      ..writeln(
        '${dryRun ? 'Preview of' : 'Imported'} $sourceNotes notes '
        '(${bySourceState['active']} active, ${bySourceState['archived']} '
        'archived, ${bySourceState['deleted']} deleted).',
      )
      ..writeln(
        'Created ${a['created']}, updated ${a['updated']}, '
        'unchanged ${a['unchanged']}, kept as conflict copies '
        '${a['conflict_copy']}, restored ${a['restored']}, '
        'skipped (older) ${a['skipped_older']}, '
        'skipped (deleted here) ${a['skipped_deleted']}.',
      );
    if (foldersCreated > 0) b.writeln('Folders created: $foldersCreated.');
    if (plainTextConverted > 0) {
      b.writeln('Plain-text notes converted: $plainTextConverted.');
    }
    if (invalidRows.isNotEmpty) {
      b.writeln('Rows skipped as invalid: ${invalidRows.length}.');
    }
    if (missingImages > 0) {
      b.writeln(
        '$missingImages image(s) in ${missingImageNoteIds.length} note(s) '
        'point to files that are not in the backup.',
      );
    }
    final kept = [
      for (final e in unsupportedFields.entries)
        if (e.value > 0) '${e.key}: ${e.value}',
    ];
    if (kept.isNotEmpty) {
      b.writeln('Kept in the import record only (no place in the app yet): '
          '${kept.join(', ')}.');
    }
    if (outOfScopeTables.isNotEmpty) {
      b.writeln(
        'Not imported (outside this app): ${outOfScopeTables.entries.map((e) => '${e.key} ${e.value}').join(', ')}.',
      );
    }
    if (tombstones > 0) {
      b.writeln('Permanent-deletion markers in the backup: $tombstones.');
    }
    for (final w in warnings) {
      b.writeln('Warning: $w');
    }
    return b.toString().trimRight();
  }
}

class RollbackReport {
  RollbackReport(this.batchId);
  final String batchId;

  /// The batch had already been rolled back; nothing was done.
  bool alreadyRolledBack = false;

  /// Imported notes removed.
  int purged = 0;

  /// Imported notes left alone because they were edited after the import.
  int keptEdited = 0;

  /// Notes whose content was put back to what it was before the import.
  int reverted = 0;
  int copiesPurged = 0;
  int copiesKept = 0;

  /// Notes already gone (deleted forever) before the rollback.
  int alreadyGone = 0;
  int foldersDeleted = 0;

  Map<String, Object?> toJson() => {
    'batchId': batchId,
    'alreadyRolledBack': alreadyRolledBack,
    'purged': purged,
    'keptEdited': keptEdited,
    'reverted': reverted,
    'copiesPurged': copiesPurged,
    'copiesKept': copiesKept,
    'alreadyGone': alreadyGone,
    'foldersDeleted': foldersDeleted,
  };

  String summary() => alreadyRolledBack
      ? 'This import was already rolled back.'
      : 'Removed $purged note(s), reverted $reverted, removed $copiesPurged '
            'conflict copies, deleted $foldersDeleted empty folder(s). Kept '
            '${keptEdited + copiesKept} that were edited since, $alreadyGone '
            'were already gone.';
}

class ImportBatchInfo {
  const ImportBatchInfo({
    required this.id,
    required this.sourceName,
    required this.formatVersion,
    required this.startedAt,
    required this.finishedAt,
    required this.rolledBackAt,
    required this.report,
  });
  final String id;
  final String? sourceName;
  final int? formatVersion;
  final int startedAt;
  final int? finishedAt;
  final int? rolledBackAt;
  final ImportReport? report;
  bool get isRolledBack => rolledBackAt != null;
}

/// Imports the legacy Notebook JSON backup (unencrypted export).
class LegacyBackupImporter {
  LegacyBackupImporter(this.repo, {int Function()? nowMs})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final NoteRepository repo;
  final int Function() _now;

  /// Parses and classifies without writing anything.
  ImportReport inspect(String jsonText, {String? sourceName}) {
    final parsed = _parse(jsonText, sourceName);
    return _run(parsed, write: false, batchId: '');
  }

  /// Imports in ONE transaction. Throws [LegacyBackupFormatException] for
  /// input that is not a legacy backup; then nothing is written.
  ///
  /// [snapshotPath]: when given and the database is on disk, a snapshot is
  /// written there before anything else. [onRecord] is a test hook called
  /// before each source note is processed; if it throws the whole import
  /// rolls back.
  ImportReport import(
    String jsonText, {
    String? sourceName,
    String? snapshotPath,
    void Function(int index)? onRecord,
  }) {
    final parsed = _parse(jsonText, sourceName);
    if (snapshotPath != null && repo.db.path != null) {
      repo.db.snapshotTo(snapshotPath);
    }
    final batchId = newId();
    return repo.db.transaction(() {
      final started = _now();
      repo.db.execute(
        '''
        INSERT INTO import_batches(id, format, format_version, source_name,
          source_hash, started_at) VALUES (?,?,?,?,?,?)
        ''',
        [
          batchId,
          'legacy-notebook',
          parsed.version,
          sourceName,
          sha256OfString(jsonText),
          started,
        ],
      );
      final report = _run(
        parsed,
        write: true,
        batchId: batchId,
        onRecord: onRecord,
      );
      repo.db.execute(
        'UPDATE import_batches SET finished_at = ?, report = ? WHERE id = ?',
        [_now(), jsonEncode(report.toJson()), batchId],
      );
      return report;
    });
  }

  /// All batches, newest first.
  List<ImportBatchInfo> batches() => [
    for (final r in repo.db.select(
      'SELECT * FROM import_batches ORDER BY rowid DESC',
    ))
      ImportBatchInfo(
        id: r['id'] as String,
        sourceName: r['source_name'] as String?,
        formatVersion: r['format_version'] as int?,
        startedAt: r['started_at'] as int,
        finishedAt: r['finished_at'] as int?,
        rolledBackAt: r['rolled_back_at'] as int?,
        report: r['report'] == null
            ? null
            : ImportReport.fromJson(
                (jsonDecode(r['report'] as String) as Map)
                    .cast<String, Object?>(),
              ),
      ),
  ];

  // ------------------------------------------------------------- rollback

  /// Undoes a batch as far as is safe: notes edited since stay. Idempotent.
  RollbackReport rollback(String batchId) {
    return repo.db.transaction(() {
      final rows = repo.db.select('SELECT * FROM import_batches WHERE id = ?', [
        batchId,
      ]);
      if (rows.isEmpty) throw ArgumentError.value(batchId, 'batchId', 'unknown');
      final out = RollbackReport(batchId);
      if (rows.first['rolled_back_at'] != null) {
        out.alreadyRolledBack = true;
        return out;
      }
      final device = repo.db.deviceId;
      final records = repo.db.select(
        'SELECT * FROM import_records WHERE batch_id = ? ORDER BY source_id',
        [batchId],
      );
      for (final r in records) {
        final action = r['action'] as String;
        final noteId = r['note_id'] as String?;
        final written = r['written_vv'] as String?;
        if (noteId == null || written == null) continue;
        if (action != ImportAction.created &&
            action != ImportAction.restored &&
            action != ImportAction.updated &&
            action != ImportAction.conflictCopy) {
          continue;
        }
        final cur = repo.getRecord(noteId);
        final isCopy = action == ImportAction.conflictCopy;
        if (cur == null || cur.purged) {
          out.alreadyGone++;
          continue;
        }
        if (cur.contentVv != VersionVector.decode(written)) {
          if (isCopy) {
            out.copiesKept++;
          } else {
            out.keptEdited++;
          }
          continue;
        }
        if (action == ImportAction.updated) {
          final prev = NoteRecord.fromJson(
            (jsonDecode(r['previous'] as String) as Map).cast<String, Object?>(),
          );
          var next = cur.copyWith(
            title: prev.title,
            body: prev.body,
            updatedAt: prev.updatedAt,
            contentHlc: repo.db.clock.now(),
            contentVv: cur.contentVv.increment(device),
          );
          // Content newer than the trash stamp would bring the note back
          // from Trash; keep it where it is.
          if (cur.trashedAt != null) {
            next = next.copyWith(trashedHlc: repo.db.clock.now());
          }
          repo.writeRecord(next);
          out.reverted++;
        } else {
          repo.purge([noteId]);
          if (isCopy) {
            out.copiesPurged++;
          } else {
            out.purged++;
          }
        }
      }
      final report = ImportReport.fromJson(
        (jsonDecode((rows.first['report'] as String?) ?? '{}') as Map)
            .cast<String, Object?>(),
      );
      for (final id in report.createdFolderIds) {
        final folder = repo.getFolderRecord(id);
        if (folder == null || folder.deleted) continue;
        final live =
            repo.db
                    .select(
                      'SELECT count(*) AS c FROM notes '
                      'WHERE folder_id = ? AND purged = 0',
                      [id],
                    )
                    .first['c']
                as int;
        if (live == 0) {
          repo.deleteFolder(id);
          out.foldersDeleted++;
        }
      }
      repo.db.execute(
        'UPDATE import_batches SET rolled_back_at = ? WHERE id = ?',
        [_now(), batchId],
      );
      return out;
    });
  }

  // --------------------------------------------------------------- images

  /// Stores the image files the backup could not carry. [filesByOriginalSource]
  /// maps the source string found in an image embed (the legacy device path or
  /// URL) to the file's bytes. Every live note referencing such a source gets
  /// the bytes stored as an attachment and the embed rewritten to `att:<hash>`
  /// through [NoteRepository.saveContent] (an ordinary local edit). Returns the
  /// number of notes changed.
  int attachImages(Map<String, Uint8List> filesByOriginalSource) {
    if (filesByOriginalSource.isEmpty) return 0;
    return repo.db.transaction(() {
      var changed = 0;
      final ids = [
        for (final r in repo.db.select(
          'SELECT id FROM notes WHERE purged = 0 ORDER BY id',
        ))
          r['id'] as String,
      ];
      for (final id in ids) {
        final note = repo.getNote(id);
        if (note == null) continue;
        final ops = decodeOps(note.body);
        var touched = false;
        for (final op in ops) {
          final insert = op['insert'];
          if (insert is! Map) continue;
          final source = insert['image'];
          if (source is! String) continue;
          final bytes = filesByOriginalSource[source];
          if (bytes == null) continue;
          final att = repo.putAttachment(bytes, _sniffMime(bytes));
          op['insert'] = {...insert, 'image': att};
          touched = true;
        }
        if (!touched) continue;
        repo.saveContent(
          id,
          title: note.title,
          body: jsonEncode(ops),
          base: note.contentVv,
        );
        changed++;
      }
      return changed;
    });
  }

  static String _sniffMime(Uint8List b) {
    bool starts(List<int> p) =>
        b.length >= p.length && [for (var i = 0; i < p.length; i++) b[i]].toString() == p.toString();
    if (starts([0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (starts([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (starts([0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (starts([0x52, 0x49, 0x46, 0x46])) return 'image/webp';
    return 'application/octet-stream';
  }

  // -------------------------------------------------------------- parsing

  _Parsed _parse(String jsonText, String? sourceName) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      throw LegacyBackupFormatException('The file is not valid JSON.');
    }
    if (decoded is! Map) {
      throw LegacyBackupFormatException(
        'The file is not a legacy backup: expected a JSON object at the top '
        'level.',
      );
    }
    final data = decoded.cast<String, Object?>();
    final looksEncrypted =
        data['encrypted'] == true ||
        (!data.containsKey('notes') &&
            data.containsKey('salt') &&
            data.containsKey('iv') &&
            data.containsKey('ciphertext'));
    if (looksEncrypted) {
      throw LegacyBackupFormatException(
        'This backup is encrypted. Export an unencrypted backup from the old '
        'app (leave the passphrase empty) and import that file.',
      );
    }
    final notes = data['notes'];
    if (notes is! List) {
      throw LegacyBackupFormatException(
        'The file is not a legacy backup: it has no "notes" list.',
      );
    }

    final report = ImportReport(sourceName: sourceName)
      ..sourceNotes = notes.length;
    final version = data['version'];
    if (version is int) {
      report.formatVersion = version;
      if (version > legacyKnownVersion) {
        report.warnings.add(
          'Backup format version $version is newer than the newest this '
          'importer knows ($legacyKnownVersion); fields it does not know are '
          'kept in the import record only.',
        );
      } else if (version < 1) {
        report.warnings.add('Backup format version $version is not valid.');
      }
    } else {
      report.warnings.add('The backup has no format version.');
    }

    final exportedRaw = data['exportedAt'];
    final exportedMs = exportedRaw is String
        ? DateTime.tryParse(exportedRaw)?.millisecondsSinceEpoch
        : null;

    for (final e in data.entries) {
      final v = e.value;
      if (v is List && !_notesTables.contains(e.key) && v.isNotEmpty) {
        report.outOfScopeTables[e.key] = v.length;
      }
    }
    final tombstones = data['deletedNotes'];
    report.tombstones = tombstones is List ? tombstones.length : 0;

    // Tags: only counted and carried in the raw record.
    final tagDefs = <String, Map<String, Object?>>{};
    final tags = data['tags'];
    if (tags is List) {
      report.tagRows = tags.length;
      for (final t in tags) {
        if (t is Map && t['name'] != null) {
          tagDefs[t['name'].toString()] = t.cast<String, Object?>();
        }
      }
    }
    final noteTags = <String, List<String>>{};
    final nt = data['noteTags'];
    if (nt is List) {
      report.noteTagRows = nt.length;
      for (final t in nt) {
        if (t is! Map || t['note_id'] == null || t['tag_name'] == null) {
          continue;
        }
        (noteTags[t['note_id'].toString()] ??= []).add(
          t['tag_name'].toString(),
        );
      }
    }

    final mapped = <_Mapped>[];
    final seen = <String>{};
    var badDates = 0;
    for (var i = 0; i < notes.length; i++) {
      final row = notes[i];
      if (row is! Map) {
        report.invalidRows.add(InvalidRow(i, 'row is not an object'));
        continue;
      }
      final m = _mapRow(
        i,
        row.cast<String, Object?>(),
        exportedMs,
        noteTags,
        tagDefs,
        () => badDates++,
      );
      if (m == null) {
        report.invalidRows.add(InvalidRow(i, 'missing or unusable id'));
        continue;
      }
      if (!seen.add(m.id)) {
        report.invalidRows.add(InvalidRow(i, 'duplicate id'));
        continue;
      }
      mapped.add(m);
    }
    if (badDates > 0) {
      report.warnings.add(
        '$badDates timestamp(s) could not be read and were replaced by the '
        'export time (or 0).',
      );
    }
    return _Parsed(report, mapped, version is int ? version : null);
  }

  _Mapped? _mapRow(
    int index,
    Map<String, Object?> row,
    int? exportedMs,
    Map<String, List<String>> noteTags,
    Map<String, Map<String, Object?>> tagDefs,
    void Function() badDate,
  ) {
    final rawId = row['id'];
    final String id;
    if (rawId is String && rawId.trim().isNotEmpty) {
      id = rawId;
    } else if (rawId is int) {
      id = '$rawId';
    } else {
      return null;
    }

    int? parse(Object? v) {
      if (v is String) {
        return DateTime.tryParse(v.trim())?.millisecondsSinceEpoch;
      }
      if (v is int) return v;
      return null;
    }

    int stamp(Object? v, int fallback) {
      final p = parse(v);
      if (p != null) return p;
      badDate();
      return fallback;
    }

    final createdParsed = parse(row['dateCreated']);
    final createdAt = createdParsed ?? _afterBad(badDate, exportedMs ?? 0);
    final modifiedParsed = parse(row['dateModified']);
    final updatedAt =
        modifiedParsed ??
        _afterBad(badDate, createdParsed ?? exportedMs ?? 0);

    final deletedRaw = row['deletedAt'];
    final deleted =
        deletedRaw != null && !(deletedRaw is String && deletedRaw.isEmpty);
    final deletedAt = deleted ? stamp(deletedRaw, updatedAt) : null;

    final title = row['title'] == null ? '' : row['title'].toString();
    final contentRaw = row['content'];
    final decoded = _asDeltaOps(contentRaw);
    final String body;
    var plain = false;
    if (decoded != null) {
      body = _canonicalBody(decoded);
    } else if (contentRaw == null ||
        (contentRaw is String && contentRaw.isEmpty)) {
      body = emptyBodyJson;
    } else {
      body = bodyFromPlainText(contentRaw.toString());
      plain = true;
    }

    final vv = VersionVector({
      'legacy:${sha256OfString('$title\u0000$body').substring(0, 16)}': 1,
    });
    final hlc = Hlc(updatedAt, 0, _legacyNode);
    final record = NoteRecord(
      id: id,
      title: title,
      body: body,
      createdAt: createdAt,
      updatedAt: updatedAt,
      contentHlc: hlc,
      contentVv: vv,
      purged: false,
      pinned: _truthy(row['isPinned']),
      pinnedHlc: hlc,
      archived: _truthy(row['isArchived']),
      archivedHlc: hlc,
      folderId: null,
      folderHlc: hlc,
      trashedAt: deletedAt,
      trashedHlc: deletedAt == null
          ? hlc
          : Hlc(
              deletedAt > updatedAt + 1 ? deletedAt : updatedAt + 1,
              0,
              _legacyNode,
            ),
      conflictOf: null,
      conflictHlc: hlc,
    );

    final category = row['category'];
    String? folderName;
    if (category is String) {
      final t = category.trim();
      if (t.isNotEmpty && t != 'All Notes' && t != 'Notes') folderName = t;
    }

    // Fields the new app has no place for.
    final carried = <String>[];
    final color = row['color'];
    final colorNum = color is num
        ? color.toInt()
        : (color is String ? int.tryParse(color) : null);
    if (color != null && colorNum != _legacyDefaultColor) carried.add('color');
    final names = noteTags[id] ?? const <String>[];
    if (names.isNotEmpty || _hasTagsField(row['tags'])) carried.add('tags');
    if (_present(row['reminderAt'])) carried.add('reminderAt');
    if (_truthy(row['isLocked'])) carried.add('isLocked');
    if (_present(row['imagePath'])) carried.add('imagePath');
    if (_present(row['previewText'])) carried.add('previewText');

    var images = 0;
    final srcs = <String>[];
    linesOf(decodeOps(body), images: srcs);
    for (final s in srcs) {
      if (!s.startsWith(attachmentScheme)) images++;
    }

    final raw = jsonEncode({
      'row': row,
      'noteTags': names,
      'tagDefs': {
        for (final n in names)
          if (tagDefs[n] != null) n: tagDefs[n],
      },
    });

    return _Mapped(
      index: index,
      id: id,
      record: record,
      vv: vv,
      folderName: folderName,
      sourceHash: sha256OfString(canonicalJson(row)),
      raw: raw,
      state: deleted
          ? 'deleted'
          : (record.archived ? 'archived' : 'active'),
      plainConverted: plain,
      carried: carried,
      missingImages: images,
    );
  }

  static int _afterBad(void Function() badDate, int v) {
    badDate();
    return v;
  }

  static bool _truthy(Object? v) =>
      v == true || v == 1 || v == '1' || v == 'true';

  static bool _present(Object? v) => v != null && !(v is String && v.isEmpty);

  static bool _hasTagsField(Object? v) {
    if (v == null) return false;
    if (v is List) return v.isNotEmpty;
    if (v is String) {
      final t = v.trim();
      if (t.isEmpty || t == '[]') return false;
      try {
        final d = jsonDecode(t);
        return d is List ? d.isNotEmpty : true;
      } on FormatException {
        return true;
      }
    }
    return true;
  }

  /// Ops of [content] when it is a Delta document, else null.
  static List<Map<String, dynamic>>? _asDeltaOps(Object? content) {
    Object? d = content;
    if (content is String) {
      final t = content.trimLeft();
      if (!t.startsWith('[') && !t.startsWith('{')) return null;
      try {
        d = jsonDecode(t);
      } on FormatException {
        return null;
      }
    }
    final list = d is Map ? d['ops'] : d;
    if (list is! List) return null;
    final ops = <Map<String, dynamic>>[];
    for (final op in list) {
      if (op is! Map || !op.containsKey('insert')) return null;
      final insert = op['insert'];
      if (insert is! String && insert is! Map) return null;
      ops.add(Map<String, dynamic>.from(op));
    }
    return ops;
  }

  /// Ops exactly as given, as a JSON array that ends with a newline.
  static String _canonicalBody(List<Map<String, dynamic>> ops) {
    final out = [...ops];
    final last = out.isEmpty ? null : out.last['insert'];
    if (last is! String || !last.endsWith('\n')) {
      out.add({'insert': '\n'});
    }
    return jsonEncode(out);
  }

  // ------------------------------------------------------- classification

  ImportReport _run(
    _Parsed p, {
    required bool write,
    required String batchId,
    void Function(int index)? onRecord,
  }) {
    final report = p.report
      ..batchId = batchId
      ..dryRun = !write;
    final db = repo.db;
    final folders = <String, String>{};

    String resolveFolder(String name) {
      final key = name.trim().toLowerCase();
      final cached = folders[key];
      if (cached != null) return cached;
      final derived = derivedId('legacy-folder', [key]);
      final rec = repo.getFolderRecord(derived);
      String id;
      if (rec != null && !rec.deleted) {
        id = derived;
      } else {
        String? sameName;
        for (final f in repo.listFolders()) {
          if (f.name.trim().toLowerCase() == key) {
            sameName = f.id;
            break;
          }
        }
        if (sameName != null) {
          id = sameName;
        } else {
          id = derived;
          report.foldersCreated++;
          report.createdFolderIds.add(id);
          if (write) {
            const born = Hlc(0, 1, _legacyNode);
            repo.writeFolderRecord(
              rec == null
                  ? FolderRecord(
                      id: id,
                      name: name.trim(),
                      nameHlc: born,
                      deleted: false,
                      deletedHlc: born,
                      createdAt: 0,
                    )
                  : FolderRecord(
                      id: rec.id,
                      name: rec.name,
                      nameHlc: rec.nameHlc,
                      deleted: false,
                      // Must beat the deletion that is being undone.
                      deletedHlc: db.clock.now(),
                      createdAt: rec.createdAt,
                    ),
            );
          }
        }
      }
      folders[key] = id;
      return id;
    }

    void count(String action) =>
        report.actions[action] = (report.actions[action] ?? 0) + 1;

    final missingNotes = <String>{};
    for (final m in p.rows) {
      onRecord?.call(m.index);
      report.bySourceState[m.state] = (report.bySourceState[m.state] ?? 0) + 1;
      if (m.plainConverted) report.plainTextConverted++;
      for (final f in m.carried) {
        report.unsupportedFields[f] = (report.unsupportedFields[f] ?? 0) + 1;
      }
      if (m.missingImages > 0) {
        report.missingImages += m.missingImages;
        missingNotes.add(m.id);
      }

      final existing = repo.getRecord(m.id);
      String action;
      if (existing == null) {
        action = ImportAction.created;
      } else if (!existing.purged) {
        final order = existing.contentVv.compare(m.vv);
        if (order == VvOrder.equal || order == VvOrder.dominates) {
          action = ImportAction.unchanged;
        } else if (existing.contentVv.counters.keys.every(
          (k) => k.startsWith('legacy:'),
        )) {
          action = m.record.updatedAt > existing.updatedAt
              ? ImportAction.updated
              : ImportAction.skippedOlder;
        } else if (_alreadyRecorded(m)) {
          action = ImportAction.unchanged;
        } else if (repo.getRecord(NoteRepository.conflictCopyOf(m.record).id) !=
            null) {
          action = ImportAction.unchanged;
        } else {
          action = ImportAction.conflictCopy;
        }
      } else {
        action = _lastWritingBatchRolledBack(m.id)
            ? ImportAction.restored
            : ImportAction.skippedDeleted;
      }
      count(action);
      if (!write) continue;

      String? noteId = m.id;
      VersionVector? writtenVv;
      String? previous;
      switch (action) {
        case ImportAction.created:
          final folderId = m.folderName == null
              ? null
              : resolveFolder(m.folderName!);
          repo.writeRecord(m.record.copyWith(folderId: folderId));
          writtenVv = m.vv;
        case ImportAction.updated:
          previous = jsonEncode(existing!.toJson());
          var next = existing.copyWith(
            title: m.record.title,
            body: m.record.body,
            updatedAt: m.record.updatedAt,
            contentHlc: m.record.contentHlc,
            contentVv: existing.contentVv.merge(m.vv),
          );
          if (existing.trashedAt != null &&
              next.contentHlc > existing.trashedHlc) {
            // Keep a trashed note in Trash: the legacy stamp of the new
            // content would otherwise count as a later edit.
            next = next.copyWith(
              trashedHlc: Hlc(m.record.updatedAt + 1, 0, _legacyNode),
            );
          }
          repo.writeRecord(next);
          writtenVv = next.contentVv;
        case ImportAction.restored:
          final hlc = db.clock.now();
          final folderId = m.folderName == null
              ? null
              : resolveFolder(m.folderName!);
          var next = existing!.copyWith(
            title: m.record.title,
            body: m.record.body,
            updatedAt: m.record.updatedAt,
            purged: false,
            contentHlc: hlc,
            contentVv: existing.contentVv.merge(m.vv).increment(db.deviceId),
            pinned: m.record.pinned,
            pinnedHlc: hlc,
            archived: m.record.archived,
            archivedHlc: hlc,
            folderId: folderId,
            folderHlc: hlc,
            trashedAt: m.record.trashedAt,
            trashedHlc: hlc,
            conflictOf: null,
            conflictHlc: hlc,
          );
          if (next.trashedAt != null) {
            // Strictly after the content stamp or normalise un-trashes it.
            next = next.copyWith(trashedHlc: db.clock.now());
          }
          repo.writeRecord(next);
          writtenVv = next.contentVv;
        case ImportAction.conflictCopy:
          final folderId = m.folderName == null
              ? null
              : resolveFolder(m.folderName!);
          final loser = m.record.copyWith(folderId: folderId);
          noteId = repo.insertConflictCopyIfAbsent(loser);
          writtenVv = repo.getRecord(noteId)!.contentVv;
        default:
          writtenVv = null;
      }
      final wrote = writtenVv != null;
      db.execute(
        '''
        INSERT INTO import_records(batch_id, source_id, source_hash, note_id,
          action, raw, previous, written_vv) VALUES (?,?,?,?,?,?,?,?)
        ''',
        [
          batchId,
          m.id,
          m.sourceHash,
          wrote || action == ImportAction.unchanged ? noteId : null,
          action,
          wrote ? m.raw : null,
          previous,
          writtenVv?.encode(),
        ],
      );
    }
    report.missingImageNoteIds
      ..clear()
      ..addAll(missingNotes.toList()..sort());
    return report;
  }

  bool _alreadyRecorded(_Mapped m) => repo.db
      .select(
        '''
        SELECT 1 FROM import_records r JOIN import_batches b ON b.id = r.batch_id
        WHERE r.source_id = ? AND r.source_hash = ? AND b.rolled_back_at IS NULL
        LIMIT 1
        ''',
        [m.id, m.sourceHash],
      )
      .isNotEmpty;

  /// Whether the newest import that wrote this note (created or revived it)
  /// has since been rolled back.
  bool _lastWritingBatchRolledBack(String id) {
    final rows = repo.db.select(
      '''
      SELECT b.rolled_back_at FROM import_records r
      JOIN import_batches b ON b.id = r.batch_id
      WHERE r.source_id = ? AND r.action IN ('created', 'restored')
      ORDER BY b.rowid DESC LIMIT 1
      ''',
      [id],
    );
    return rows.isNotEmpty && rows.first['rolled_back_at'] != null;
  }
}

/// JSON with object keys sorted recursively; the form hashed into
/// `source_hash`.
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return [for (final e in v) _sorted(e)];
  return v;
}

class _Parsed {
  _Parsed(this.report, this.rows, this.version);
  final ImportReport report;
  final List<_Mapped> rows;
  final int? version;
}

class _Mapped {
  _Mapped({
    required this.index,
    required this.id,
    required this.record,
    required this.vv,
    required this.folderName,
    required this.sourceHash,
    required this.raw,
    required this.state,
    required this.plainConverted,
    required this.carried,
    required this.missingImages,
  });
  final int index;
  final String id;
  final NoteRecord record;
  final VersionVector vv;
  final String? folderName;
  final String sourceHash;
  final String raw;
  final String state;
  final bool plainConverted;
  final List<String> carried;
  final int missingImages;
}
