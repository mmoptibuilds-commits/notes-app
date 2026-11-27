import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';

void main() {
  test('isolated process writer helper', () async {
    final environment = Platform.environment;
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

Future<void> _waitForRelease(String path) async {
  while (!File(path).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
