import 'dart:io';

import '../core/ids.dart';

typedef AtomicExportTempWriter = Future<void> Function(
  File temporaryFile,
  String contents,
);

/// Replaces [target] through a flushed temporary file in the same directory.
/// On filesystems with atomic rename, a failed write leaves the prior export
/// intact. The optional writer exists so tests can inject a mid-write failure.
Future<void> writeExportAtomically(
  File target,
  String contents, {
  AtomicExportTempWriter? writeTemporary,
}) async {
  final temporary = File('${target.path}.tmp-${newId()}');
  try {
    await temporary.create(exclusive: true);
    if (writeTemporary == null) {
      await temporary.writeAsString(contents, flush: true);
    } else {
      await writeTemporary(temporary, contents);
    }
    await temporary.rename(target.path);
  } on Object {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on Object {
      // Preserve the original write/rename error if cleanup also fails.
    }
    rethrow;
  }
}
