import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../data/models.dart';
import '../data/note_repository.dart';

const exportFormat = 'notes-export';
const exportVersion = 1;

class ExportAttachment {
  const ExportAttachment({
    required this.hash,
    required this.mime,
    required this.data,
  });
  final String hash;
  final String mime;
  final Uint8List data;
  int get size => data.length;
}

/// A parsed export file. Merging it into a database is the caller's job.
class ExportContents {
  const ExportContents({
    required this.version,
    required this.exportedAt,
    required this.deviceId,
    required this.notes,
    required this.folders,
    required this.attachments,
  });
  final int version;
  final DateTime exportedAt;
  final String deviceId;
  final List<NoteRecord> notes;
  final List<FolderRecord> folders;
  final List<ExportAttachment> attachments;
}

/// Every note (including deleted-forever tombstones), folder and stored
/// attachment as one JSON document.
String exportAll(NoteRepository repo, {DateTime? now}) {
  final attachments = [
    for (final r in repo.db.select(
      'SELECT hash, mime, size, data FROM attachments '
      'WHERE data IS NOT NULL ORDER BY hash',
    ))
      {
        'hash': r['hash'],
        'mime': r['mime'],
        'size': r['size'],
        'data': base64Encode(r['data'] as Uint8List),
      },
  ];
  return const JsonEncoder.withIndent('  ').convert({
    'format': exportFormat,
    'version': exportVersion,
    'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'deviceId': repo.db.deviceId,
    'notes': [for (final (_, r) in repo.noteRecordsSince(0)) r.toJson()],
    'folders': [for (final (_, r) in repo.folderRecordsSince(0)) r.toJson()],
    'attachments': attachments,
  });
}

/// Validates and decodes an export. Throws [FormatException] for anything that
/// is not a `notes-export` version this build understands.
ExportContents parseExport(String json) {
  final Object? raw;
  try {
    raw = jsonDecode(json);
  } on FormatException {
    throw const FormatException('Not valid JSON');
  }
  if (raw is! Map || raw['format'] != exportFormat) {
    throw const FormatException('Not a Notes export');
  }
  final version = raw['version'];
  if (version is! int || version < 1 || version > exportVersion) {
    throw FormatException('Unsupported export version', version);
  }
  try {
    return ExportContents(
      version: version,
      exportedAt: DateTime.parse(raw['exportedAt'] as String),
      deviceId: raw['deviceId'] as String,
      notes: [
        for (final n in raw['notes'] as List)
          NoteRecord.fromJson((n as Map).cast<String, Object?>()),
      ],
      folders: [
        for (final f in raw['folders'] as List)
          FolderRecord.fromJson((f as Map).cast<String, Object?>()),
      ],
      attachments: [
        for (final a in raw['attachments'] as List) _attachment(a as Map),
      ],
    );
  } on FormatException {
    rethrow;
  } on Object catch (e) {
    throw FormatException('Malformed export: ${e.runtimeType}');
  }
}

ExportAttachment _attachment(Map a) {
  final data = base64Decode(a['data'] as String);
  final hash = a['hash'] as String;
  if (sha256Hex(data) != hash || (a['size'] as num).toInt() != data.length) {
    throw const FormatException('Attachment does not match its hash');
  }
  return ExportAttachment(
    hash: hash,
    mime: a['mime'] as String,
    data: Uint8List.fromList(data),
  );
}
