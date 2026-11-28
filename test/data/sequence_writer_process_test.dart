import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/platform/bootstrap.dart';

void main() {
  test('isolated process writer helper', () async {
    final environment = Platform.environment;
    final bootstrapDir = environment['NOTES_BOOTSTRAP_DIR'];
    if (bootstrapDir != null) {
      final store = _DelayedFileKeyStore(
        '$bootstrapDir/dev.key',
        readDelay: Duration(
          milliseconds: int.parse(
            environment['NOTES_BOOTSTRAP_READ_DELAY_MS'] ?? '0',
          ),
        ),
        writeDelay: Duration(
          milliseconds: int.parse(
            environment['NOTES_BOOTSTRAP_WRITE_DELAY_MS'] ?? '0',
          ),
        ),
      );
      final app = await bootstrap(dataDir: bootstrapDir, keyStore: store);
      app.notes.createNote(title: environment['NOTES_BOOTSTRAP_TITLE']!);
      app.close();
      return;
    }

    final databasePath = environment['NOTES_PROCESS_DB'];
    if (databasePath == null) return;

    if (environment['NOTES_PROCESS_HOLD_OPEN_LOCK'] == 'true') {
      final lock = File('$databasePath.open.lock')
          .openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
      File(environment['NOTES_PROCESS_PID']!).writeAsStringSync('$pid');
      File(environment['NOTES_PROCESS_READY']!).writeAsStringSync('ready');
      await _waitForRelease(environment['NOTES_PROCESS_RELEASE']!);
      lock.unlockSync();
      lock.closeSync();
      return;
    }

    final draftLockId = environment['NOTES_PROCESS_DRAFT_LOCK_ID'];
    if (draftLockId != null) {
      final db = AppDatabase.open(databasePath);
      final repo = NoteRepository(db);
      final lease = repo.acquireEditorDraftLease(draftLockId);
      if (lease == null) throw StateError('draft lock was unexpectedly busy');
      File(environment['NOTES_PROCESS_READY']!).writeAsStringSync('ready');
      await _waitForRelease(environment['NOTES_PROCESS_RELEASE']!);
      lease.release();
      repo.dispose();
      db.close();
      return;
    }

    final snapshotTarget = environment['NOTES_PROCESS_SNAPSHOT_TARGET'];
    if (snapshotTarget != null) {
      final db = AppDatabase.open(databasePath);
      File(environment['NOTES_PROCESS_READY']!).writeAsStringSync('ready');
      await _waitForRelease(environment['NOTES_PROCESS_RELEASE']!);
      try {
        db.snapshotTo(snapshotTarget);
        File(environment['NOTES_PROCESS_RESULT']!).writeAsStringSync('created');
      } on FileSystemException {
        File(environment['NOTES_PROCESS_RESULT']!).writeAsStringSync('exists');
      }
      db.close();
      return;
    }

    final db = AppDatabase.open(databasePath, wallClock: () => 5000);
    final repo = NoteRepository(db, nowMs: () => 5000);
    File(environment['NOTES_PROCESS_READY']!).writeAsStringSync('ready');
    await _waitForRelease(environment['NOTES_PROCESS_RELEASE']!);
    repo.createNote(title: environment['NOTES_PROCESS_TITLE']!);
    repo.dispose();
    db.close();
  });
}

class _DelayedFileKeyStore implements KeyStore {
  _DelayedFileKeyStore(
    this.path, {
    required this.readDelay,
    required this.writeDelay,
  });

  final String path;
  final Duration readDelay;
  final Duration writeDelay;

  @override
  Future<Uint8List?> read() async {
    final file = File(path);
    final value = file.existsSync()
        ? Uint8List.fromList(base64Decode(file.readAsStringSync()))
        : null;
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    return value;
  }

  @override
  Future<void> write(Uint8List key) async {
    if (writeDelay > Duration.zero) await Future<void>.delayed(writeDelay);
    File(path).writeAsStringSync(base64Encode(key), flush: true);
  }
}

Future<void> _waitForRelease(String path) async {
  while (!File(path).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
