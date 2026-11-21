import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';

void main() {
  test('automatic update checks default on and can be turned off', () {
    final app = AppServices.inMemory();
    addTearDown(app.close);
    expect(app.settings.autoCheckUpdates, isTrue);
    app.settings.autoCheckUpdates = false;
    expect(app.settings.autoCheckUpdates, isFalse);
  });

  test('startup view defaults to Unfiled and parses stored enum values', () {
    final app = AppServices.inMemory();
    addTearDown(app.close);

    expect(app.settings.read('startupView'), isNull);
    expect(app.settings.startupView, StartupView.unfiled);

    app.settings.startupView = StartupView.all;
    expect(app.settings.read('startupView'), 'all');
    expect(app.settings.startupView, StartupView.all);

    app.settings.write('startupView', 'unfiled');
    expect(app.settings.startupView, StartupView.unfiled);

    app.settings.write('startupView', 'last');
    expect(app.settings.startupView, StartupView.last);

    app.settings.write('startupView', 'future-value');
    expect(app.settings.startupView, StartupView.unfiled);
  });

  test('writeSilently persists without notifying listeners', () {
    final app = AppServices.inMemory();
    addTearDown(app.close);
    var notified = 0;
    app.settings.addListener(() => notified++);
    app.settings.writeSilently('update.lastCheck', '123');
    expect(app.settings.read('update.lastCheck'), '123');
    app.settings.writeSilently('update.lastCheck', null);
    expect(app.settings.read('update.lastCheck'), isNull);
    expect(notified, 0);
    final reopened = app.db.raw
        .select(
          "SELECT count(*) c FROM settings WHERE key = 'update.lastCheck'",
        )
        .first['c'];
    expect(reopened, 0);
  });
}
