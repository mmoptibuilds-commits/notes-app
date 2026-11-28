import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/update/update_state.dart';

void main() {
  test('replay version and build are committed atomically', () {
    final db = AppDatabase.open(null);
    final settings = AppSettings(db);
    final store = AppSettingsUpdateStore(settings);
    db.execute('''
      CREATE TRIGGER reject_highest_build BEFORE INSERT ON settings
      WHEN NEW.key = 'update.highestBuild'
      BEGIN SELECT RAISE(ABORT, 'synthetic settings failure'); END
    ''');

    expect(
      () => store.advanceReplayMark('1.3.2', 20261128),
      throwsA(isA<UpdateStateWriteException>()),
    );
    expect(store.read(UpdateKeys.highestVersion), isNull);
    expect(store.read(UpdateKeys.highestBuild), isNull);
    expect(
      db.select(
        "SELECT value FROM settings WHERE key = 'update.highestVersion'",
      ),
      isEmpty,
    );

    db.execute('DROP TRIGGER reject_highest_build');
    expect(store.advanceReplayMark('1.3.2', 20261128), isTrue);
    expect(store.read(UpdateKeys.highestVersion), '1.3.2');
    expect(store.read(UpdateKeys.highestBuild), '20261128');

    settings.dispose();
    db.close();
  });

  test('replay checks and updates use persisted values across app windows', () {
    final directory = Directory.systemTemp.createTempSync(
      'notes-replay-mark-test-',
    );
    final path = '${directory.path}/notes.db';
    final firstDb = AppDatabase.open(path);
    final secondDb = AppDatabase.open(path);
    final firstSettings = AppSettings(firstDb);
    final secondSettings = AppSettings(secondDb);
    final first = AppSettingsUpdateStore(firstSettings);
    final second = AppSettingsUpdateStore(secondSettings);

    expect(first.advanceReplayMark('1.3.2', 20261128), isTrue);
    expect(second.replayMarkAllows('1.3.1', 99999999), isFalse);
    expect(second.advanceReplayMark('1.3.1', 99999999), isFalse);
    expect(second.replayMarkAllows('1.3.2', 20261128), isTrue);
    expect(
      secondDb
          .select(
            "SELECT value FROM settings WHERE key = 'update.highestVersion'",
          )
          .single['value'],
      '1.3.2',
    );
    expect(
      secondDb
          .select(
            "SELECT value FROM settings WHERE key = 'update.highestBuild'",
          )
          .single['value'],
      '20261128',
    );

    firstSettings.dispose();
    secondSettings.dispose();
    firstDb.close();
    secondDb.close();
    directory.deleteSync(recursive: true);
  });
}
