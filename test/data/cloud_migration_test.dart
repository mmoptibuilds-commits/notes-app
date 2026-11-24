import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/migrations.dart';
import 'package:notes/data/note_repository.dart';

void main() {
  test(
    'version 3 upgrades to 4 and preserves records with a pre-v4 backup',
    () {
      final dir = Directory.systemTemp.createTempSync('notes cloud migration ');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/notes.db';
      final old = AppDatabase.open(path, schema: migrations.sublist(0, 3));
      final repo = NoteRepository(old);
      final folder = repo.createFolder('Synthetic folder');
      final note = repo.createNote(
        title: 'Synthetic note',
        folderId: folder.id,
      );
      old.close();

      final upgraded = AppDatabase.open(path);
      addTearDown(upgraded.close);
      final upgradedRepo = NoteRepository(upgraded);
      expect(upgraded.raw.userVersion, 4);
      expect(upgradedRepo.getNote(note.id)?.title, 'Synthetic note');
      expect(upgradedRepo.getFolderRecord(folder.id)?.name, 'Synthetic folder');
      expect(upgraded.select('PRAGMA table_info(cloud_notes)').length, 8);
      expect(File('$path.pre-v4.bak').existsSync(), isTrue);
    },
  );
}
