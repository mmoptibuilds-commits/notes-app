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
      () => store.writeAll({
        UpdateKeys.highestVersion: '1.3.2',
        UpdateKeys.highestBuild: '20261128',
      }),
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
    store.writeAll({
      UpdateKeys.highestVersion: '1.3.2',
      UpdateKeys.highestBuild: '20261128',
    });
    expect(store.read(UpdateKeys.highestVersion), '1.3.2');
    expect(store.read(UpdateKeys.highestBuild), '20261128');

    settings.dispose();
    db.close();
  });
}
