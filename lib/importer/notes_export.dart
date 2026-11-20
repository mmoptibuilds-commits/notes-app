import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../data/models.dart';
import '../data/note_repository.dart';
import '../doc/delta_text.dart';

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
  if (raw is! Map) {
    throw const FormatException(
      'Unrecognized file format. Choose a Notes export or a Notebook backup.',
    );
  }
  if (raw['format'] != exportFormat) {
    if (raw.containsKey('deviceId') &&
        raw.containsKey('folders') &&
        raw.containsKey('attachments')) {
      throw const FormatException(
        'This file has an unrecognized Notes export format name.',
      );
    }
    if (raw['notes'] is List) {
      throw const FormatException(
        'This is a Notebook backup, not a Notes export. Choose the Notebook '
        'backup import option.',
      );
    }
    throw const FormatException(
      'Unrecognized file format. Choose a Notes export or a Notebook backup.',
    );
  }
  final version = raw['version'];
  if (version is! int || version < 1) {
    throw const FormatException(
      'The Notes export has a missing or malformed version.',
    );
  }
  if (version > exportVersion) {
    throw FormatException(
      'This Notes export uses version $version; this app supports version '
      '$exportVersion.',
    );
  }
  try {
    final exportedAtValue = raw['exportedAt'];
    final deviceIdValue = raw['deviceId'];
    if (exportedAtValue is! String ||
        deviceIdValue is! String ||
        deviceIdValue.isEmpty) {
      throw const FormatException('Missing export metadata.');
    }
    final rawNotes = raw['notes'];
    final rawFolders = raw['folders'];
    final rawAttachments = raw['attachments'];
    if (rawNotes is! List || rawFolders is! List || rawAttachments is! List) {
      throw const FormatException('Missing notes, folders, or attachments.');
    }
    final noteIds = <String>{};
    final folderIds = <String>{};
    final attachmentHashes = <String>{};
    return ExportContents(
      version: version,
      exportedAt: DateTime.parse(exportedAtValue),
      deviceId: deviceIdValue,
      notes: [
        for (final (index, value) in rawNotes.indexed)
          _note(value, index, noteIds),
      ],
      folders: [
        for (final (index, value) in rawFolders.indexed)
          _folder(value, index, folderIds),
      ],
      attachments: [
        for (final (index, value) in rawAttachments.indexed)
          _attachment(value, index, attachmentHashes),
      ],
    );
  } on FormatException {
    rethrow;
  } on Object catch (e) {
    throw FormatException('Malformed Notes export: ${e.runtimeType}.');
  }
}

NoteRecord _note(Object? value, int index, Set<String> ids) {
  if (value is! Map) {
    throw FormatException('Note $index is not an object.');
  }
  final j = value.cast<String, Object?>();
  final id = j['id'];
  final title = j['title'];
  final body = j['body'];
  final vector = j['contentVv'];
  if (id is! String || id.isEmpty || !ids.add(id)) {
    throw FormatException('Note $index has a missing or duplicate id.');
  }
  if (title is! String || body is! String) {
    throw FormatException('Note $index has a malformed title or body.');
  }
  for (final field in ['createdAt', 'updatedAt']) {
    if (j[field] is! int) {
      throw FormatException('Note $index has a malformed $field.');
    }
  }
  for (final field in ['purged', 'pinned', 'archived']) {
    if (j[field] is! bool) {
      throw FormatException('Note $index has a malformed $field flag.');
    }
  }
  if (j['folderId'] != null && j['folderId'] is! String) {
    throw FormatException('Note $index has a malformed folder id.');
  }
  if (j['trashedAt'] != null && j['trashedAt'] is! int) {
    throw FormatException('Note $index has a malformed trash timestamp.');
  }
  if (j['conflictOf'] != null && j['conflictOf'] is! String) {
    throw FormatException('Note $index has a malformed conflict id.');
  }
  if (vector is! Map ||
      vector.isEmpty ||
      vector.entries.any(
        (e) =>
            e.key is! String ||
            (e.key as String).isEmpty ||
            e.value is! int ||
            (e.value as int) < 1,
      )) {
    throw FormatException('Note $index has a malformed version vector.');
  }
  for (final field in [
    'contentHlc',
    'pinnedHlc',
    'archivedHlc',
    'folderHlc',
    'trashedHlc',
    'conflictHlc',
  ]) {
    if (j[field] is! String) {
      throw FormatException('Note $index has a malformed $field.');
    }
  }
  try {
    decodeOps(body);
    return NoteRecord.fromJson(j);
  } on FormatException catch (e) {
    throw FormatException('Note $index is malformed: ${e.message}.');
  } on Object {
    throw FormatException('Note $index is malformed.');
  }
}

FolderRecord _folder(Object? value, int index, Set<String> ids) {
  if (value is! Map) {
    throw FormatException('Folder $index is not an object.');
  }
  final j = value.cast<String, Object?>();
  final id = j['id'];
  if (id is! String || id.isEmpty || !ids.add(id)) {
    throw FormatException('Folder $index has a missing or duplicate id.');
  }
  if (j['name'] is! String || (j['name'] as String).isEmpty) {
    throw FormatException('Folder $index has a malformed name.');
  }
  if (j['deleted'] is! bool || j['createdAt'] is! int) {
    throw FormatException('Folder $index has malformed metadata.');
  }
  if (j['nameHlc'] is! String || j['deletedHlc'] is! String) {
    throw FormatException('Folder $index has malformed clocks.');
  }
  try {
    return FolderRecord.fromJson(j);
  } on Object {
    throw FormatException('Folder $index is malformed.');
  }
}

ExportAttachment _attachment(Object? value, int index, Set<String> hashes) {
  if (value is! Map) {
    throw FormatException('Attachment $index is not an object.');
  }
  final hash = value['hash'];
  final mime = value['mime'];
  final size = value['size'];
  final encoded = value['data'];
  if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
    throw FormatException('Attachment $index has a malformed hash.');
  }
  if (!hashes.add(hash)) {
    throw FormatException('Attachment $index repeats hash $hash.');
  }
  if (mime is! String || size is! int || size < 0 || encoded is! String) {
    throw FormatException('Attachment $index has malformed metadata.');
  }
  final Uint8List data;
  try {
    data = Uint8List.fromList(base64Decode(encoded));
  } on FormatException {
    throw FormatException('Attachment $index has invalid or truncated data.');
  }
  if (sha256Hex(data) != hash || size != data.length) {
    throw FormatException(
      'Attachment $index does not match its declared hash and size.',
    );
  }
  return ExportAttachment(hash: hash, mime: mime, data: data);
}
