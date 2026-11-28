import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/platform/bootstrap.dart';

String _flutterBinary() {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  return '$root/bin/flutter';
}

class _RacingKeyStore implements KeyStore {
  Uint8List? value;

  @override
  Future<Uint8List?> read() async {
    final seen = value == null ? null : Uint8List.fromList(value!);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return seen;
  }

  @override
  Future<void> write(Uint8List key) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    value = Uint8List.fromList(key);
  }
}

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

  test('simultaneous first launches retain one key and every note', () async {
    Future<Process> launch(String title, int writeDelayMs) => Process.start(
      _flutterBinary(),
      ['test', '--no-pub', 'test/data/sequence_writer_process_test.dart'],
      environment: {
        ...Platform.environment,
        'NOTES_BOOTSTRAP_DIR': dir.path,
        'NOTES_BOOTSTRAP_TITLE': title,
        'NOTES_BOOTSTRAP_READ_DELAY_MS': '250',
        'NOTES_BOOTSTRAP_WRITE_DELAY_MS': '$writeDelayMs',
      },
      workingDirectory: Directory.current.path,
    );

    final first = await launch('First launch', 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final second = await launch('Second launch', 500);
    final output = Future.wait([
      first.stdout.transform(utf8.decoder).join(),
      first.stderr.transform(utf8.decoder).join(),
      second.stdout.transform(utf8.decoder).join(),
      second.stderr.transform(utf8.decoder).join(),
    ]);
    final firstExit = await first.exitCode;
    final secondExit = await second.exitCode;
    final logs = await output;
    expect(firstExit, 0, reason: logs.join('\n'));
    expect(secondExit, 0, reason: logs.join('\n'));

    final reopened = await bootstrap(dataDir: dir.path);
    expect(reopened.notes.listNotes(), hasLength(2));
    expect(reopened.notes.listNotes().map((note) => note.title).toSet(), {
      'First launch',
      'Second launch',
    });
    reopened.close();
  });

  test('same-process first launches share one key and database', () async {
    final store = _RacingKeyStore();
    final apps = await Future.wait([
      bootstrap(dataDir: dir.path, keyStore: store),
      bootstrap(dataDir: dir.path, keyStore: store),
    ]);
    apps.first.notes.createNote(title: 'First');
    apps.last.notes.createNote(title: 'Second');
    expect(apps.first.notes.listNotes(), hasLength(2));
    for (final app in apps) {
      app.close();
    }
    final reopened = await bootstrap(dataDir: dir.path, keyStore: store);
    expect(reopened.notes.listNotes(), hasLength(2));
    reopened.close();
  });

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
