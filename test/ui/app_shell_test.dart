import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../support/screenshot.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('app starts on the library and follows theme settings', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(412, 915));
    await pumpApp(tester, services);
    BuildContext ctx() => tester.element(find.text('All notes'));
    expect(AppPalette.of(ctx()).background, AppPalette.amoled.background);
    services.settings.theme = AppTheme.light;
    await tester.pumpAndSettle();
    expect(AppPalette.of(ctx()).background, AppPalette.light.background);
    services.settings.animations = AnimationLevel.off;
    await tester.pumpAndSettle();
    expect(AppMotion.of(ctx()).page, Duration.zero);
    await screenshot(tester, 'shell');
  });

  test('settings persist across reopen and ignore bad stored values', () {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    final s = services.settings;
    s.layout = LibraryLayout.list;
    s.textScale = 9;
    s.toolbar = [ToolbarItem.bold, ToolbarItem.link];
    services.db.execute("INSERT INTO settings VALUES ('theme', 'neon')");
    final again = AppSettings(services.db);
    expect(again.layout, LibraryLayout.list);
    expect(again.textScale, 1.4);
    expect(again.toolbar, [ToolbarItem.bold, ToolbarItem.link]);
    expect(again.theme, AppTheme.amoled);
    again.dispose();
  });
}
