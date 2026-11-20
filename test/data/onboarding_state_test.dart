import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/platform/bootstrap.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('notes onboarding '));
  tearDown(() => dir.deleteSync(recursive: true));

  final key = Uint8List.fromList(List.filled(32, 7));

  test(
    'only a database created by this launch is pending onboarding',
    () async {
      final first = await bootstrap(dataDir: dir.path);
      expect(first.db.createdNow, isTrue);
      expect(first.settings.onboardingPending, isTrue);
      expect(first.settings.hasUserData, isFalse);
      first.close();

      // Relaunch before finishing: still pending, but the database is not new.
      final second = await bootstrap(dataDir: dir.path);
      expect(second.db.createdNow, isFalse);
      expect(second.settings.onboardingPending, isTrue);
      second.settings.completeOnboarding();
      second.close();

      final third = await bootstrap(dataDir: dir.path);
      expect(third.settings.onboardingPending, isFalse);
      third.close();
    },
  );

  test(
    'an existing database without the flag never shows onboarding',
    () async {
      final path = '${dir.path}/notes.db';
      final old = AppDatabase.open(path, key: key);
      NoteRepository(old).createNote(title: 't', body: '[{"insert":"b\\n"}]');
      old.close();
      File('${dir.path}/dev.key').writeAsStringSync(base64Encode(key));

      final app = await bootstrap(dataDir: dir.path);
      expect(app.db.createdNow, isFalse);
      expect(app.settings.onboardingPending, isFalse);
      expect(app.settings.hasUserData, isTrue);
      expect(app.notes.counts().active, 1);
      app.close();
    },
  );

  test('in-memory services start without onboarding', () {
    final app = AppServices.inMemory();
    expect(app.settings.onboardingPending, isFalse);
    app.close();
  });

  test('hidden rows count as user data (trashed, archived, folders)', () {
    final app = AppServices.inMemory();
    expect(app.settings.hasUserData, isFalse);
    final n = app.notes.createNote(title: 'x', body: '[{"insert":"\\n"}]');
    app.notes.trash([n.id]);
    expect(app.settings.hasUserData, isTrue);
    app.close();
  });

  test('completing onboarding writes no note rows', () {
    final app = AppServices.inMemory();
    app.settings.write('onboarding', 'pending');
    final before = app.db.raw.select('SELECT count(*) c FROM notes').first['c'];
    app.settings.completeOnboarding();
    expect(app.settings.onboardingPending, isFalse);
    expect(
      app.db.raw.select('SELECT count(*) c FROM notes').first['c'],
      before,
    );
    app.close();
  });
}
