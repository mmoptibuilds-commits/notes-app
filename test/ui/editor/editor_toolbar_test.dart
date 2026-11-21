import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/editor/editor_toolbar.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../../support/screenshot.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('toolbar fades reveal hidden controls without motion when off', (
    tester,
  ) async {
    final services = AppServices.inMemory();
    addTearDown(services.close);
    services.settings.animations = AnimationLevel.off;
    final controller = QuillController.basic();
    addTearDown(controller.dispose);
    await setWindow(tester, const Size(320, 120));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(services.settings),
        home: Scaffold(
          body: EditorToolbar(
            controller: controller,
            items: ToolbarItem.values,
            onLink: () async {},
            onImage: () async {},
            bottom: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final leading = find.byKey(const ValueKey('editor-toolbar-leading-fade'));
    final trailing = find.byKey(const ValueKey('editor-toolbar-trailing-fade'));
    expect(tester.widget<AnimatedOpacity>(leading).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(trailing).opacity, 1);
    expect(tester.widget<AnimatedOpacity>(trailing).duration, Duration.zero);

    await tester.drag(find.byType(ListView), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(leading).opacity, 1);

    await tester.drag(find.byType(ListView), const Offset(-10000, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(trailing).opacity, 0);
    expect(tester.takeException(), isNull);
  });
}
