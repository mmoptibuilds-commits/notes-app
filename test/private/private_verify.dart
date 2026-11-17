import 'dart:convert';

import 'package:notes/core/ids.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/importer/legacy_backup.dart';

/// Verification of an import against its source that never reveals note
/// content: failures name a note by its index in the source and the field
/// that differs, nothing else.

class VerifyResult {
  VerifyResult();
  int sourceNotes = 0;
  int active = 0;
  int archived = 0;
  int deleted = 0;
  int landedActive = 0;
  int landedArchived = 0;
  int landedTrash = 0;
  int reimportCreated = 0;
  int reimportUnchanged = 0;
  int reimportSeqDelta = 0;
  int unreadableDates = 0;
  int plainTextConverted = 0;
  String idsHash = '';
  ImportReport? report;
  final List<String> failures = [];

  bool get ok => failures.isEmpty;

  /// Numbers only.
  Map<String, Object?> numbers() => {
    'sourceNotes': sourceNotes,
    'sourceActive': active,
    'sourceArchived': archived,
    'sourceDeleted': deleted,
    'landedActive': landedActive,
    'landedArchived': landedArchived,
    'landedTrash': landedTrash,
    'reimportCreated': reimportCreated,
    'reimportUnchanged': reimportUnchanged,
    'reimportSeqDelta': reimportSeqDelta,
    'unreadableDates': unreadableDates,
    'plainTextConverted': plainTextConverted,
    'idsSha256': idsHash,
    'failures': failures.length,
    if (report != null) 'report': _numericOnly(report!.toJson()),
  };
}

Object? _numericOnly(Object? v) {
  if (v is num || v is bool) return v;
  if (v is Map) {
    return {
      for (final e in v.entries)
        if (_numericOnly(e.value) != null) e.key: _numericOnly(e.value),
    };
  }
  if (v is List) return v.length; // counts only: ids and reasons stay out
  return null;
}

bool _truthy(Object? v) => v == true || v == 1 || v == '1' || v == 'true';

String? _idOf(Object? raw) {
  if (raw is String && raw.trim().isNotEmpty) return raw;
  if (raw is int) return '$raw';
  return null;
}

int? _ms(Object? v) =>
    v is String ? DateTime.tryParse(v.trim())?.millisecondsSinceEpoch : null;

/// The body the importer must store for [content]: the source ops unchanged
/// (plus a final newline if missing), or plain text.
String expectedBodyFor(Object? content) {
  Object? d = content;
  if (content is String) {
    final t = content.trimLeft();
    if (t.startsWith('[') || t.startsWith('{')) {
      try {
        d = jsonDecode(t);
      } on FormatException {
        d = null;
      }
    } else {
      d = null;
    }
  }
  final list = d is Map ? d['ops'] : d;
  final isDelta =
      list is List &&
      list.every(
        (o) =>
            o is Map &&
            o.containsKey('insert') &&
            (o['insert'] is String || o['insert'] is Map),
      );
  if (!isDelta) {
    if (content == null || (content is String && content.isEmpty)) {
      return emptyBodyJson;
    }
    return bodyFromPlainText(content.toString());
  }
  final ops = [...list];
  final last = ops.isEmpty ? null : (ops.last as Map)['insert'];
  if (last is! String || !last.endsWith('\n')) ops.add({'insert': '\n'});
  return jsonEncode(ops);
}

/// Differences between one source row and the stored record, as field names.
/// Empty means the note matches.
List<String> compareNote(Map<String, Object?> row, NoteRecord rec) {
  final out = <String>[];
  if (rec.body != expectedBodyFor(row['content'])) out.add('body');
  final title = row['title'] == null ? '' : row['title'].toString();
  if (rec.title != title) out.add('title');
  if (rec.pinned != _truthy(row['isPinned'])) out.add('pinned');
  if (rec.archived != _truthy(row['isArchived'])) out.add('archived');
  final deletedRaw = row['deletedAt'];
  final deleted =
      deletedRaw != null && !(deletedRaw is String && deletedRaw.isEmpty);
  if ((rec.trashedAt != null) != deleted) out.add('trashed');
  final created = _ms(row['dateCreated']);
  if (created != null && rec.createdAt != created) out.add('createdAt');
  final modified = _ms(row['dateModified']);
  if (modified != null && rec.updatedAt != modified) out.add('updatedAt');
  final deletedMs = _ms(deletedRaw);
  if (deleted && deletedMs != null && rec.trashedAt != deletedMs) {
    out.add('trashedAt');
  }
  if (rec.purged) out.add('purged');
  return out;
}

/// Imports [jsonText] into a fresh in-memory database and compares the result
/// with the source. [tamper] runs between import and comparison (tests use it
/// to prove that a mismatch is caught).
VerifyResult verifyImport(
  String jsonText, {
  void Function(NoteRepository repo)? tamper,
}) {
  final result = VerifyResult();
  final source = (jsonDecode(jsonText) as Map).cast<String, Object?>();
  final rows = (source['notes'] as List)
      .map((r) => r is Map ? r.cast<String, Object?>() : null)
      .toList();
  result.sourceNotes = rows.length;

  final db = AppDatabase.open(null);
  try {
    final repo = NoteRepository(db);
    final importer = LegacyBackupImporter(repo);
    result.report = importer.import(jsonText);
    result.plainTextConverted = result.report!.plainTextConverted;
    tamper?.call(repo);

    final ids = <String>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final id = row == null ? null : _idOf(row['id']);
      if (row == null || id == null) {
        result.failures.add('note #$i: unusable source row');
        continue;
      }
      ids.add(id);
      final deletedRaw = row['deletedAt'];
      if (deletedRaw != null && !(deletedRaw is String && deletedRaw.isEmpty)) {
        result.deleted++;
      } else if (_truthy(row['isArchived'])) {
        result.archived++;
      } else {
        result.active++;
      }
      if (_ms(row['dateCreated']) == null || _ms(row['dateModified']) == null) {
        result.unreadableDates++;
      }
      final rec = repo.getRecord(id);
      if (rec == null || rec.purged) {
        result.failures.add('note #$i: missing');
        continue;
      }
      for (final f in compareNote(row, rec)) {
        result.failures.add('note #$i: $f differs');
      }
    }
    ids.sort();
    result.idsHash = sha256OfString(ids.join('\n'));

    final c = repo.counts();
    result.landedActive = c.active;
    result.landedArchived = c.archived;
    result.landedTrash = c.trash;
    if (c.active != result.active) result.failures.add('active count differs');
    if (c.archived != result.archived) {
      result.failures.add('archived count differs');
    }
    if (c.trash != result.deleted) result.failures.add('trash count differs');

    final seq = db.currentSeq;
    final again = importer.import(jsonText);
    result.reimportCreated = again.actions['created'] ?? 0;
    result.reimportUnchanged = again.actions['unchanged'] ?? 0;
    result.reimportSeqDelta = db.currentSeq - seq;
    if (result.reimportSeqDelta != 0) {
      result.failures.add('re-import wrote ${result.reimportSeqDelta} rows');
    }
    if (result.reimportCreated != 0) {
      result.failures.add('re-import created notes');
    }
  } finally {
    db.close();
  }
  return result;
}
