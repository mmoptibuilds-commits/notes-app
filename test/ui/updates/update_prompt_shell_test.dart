import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/theme/app_theme.dart';
import 'package:notes/ui/updates/update_prompt_shell.dart';
import 'package:notes/ui/updates/updates_screen.dart';
import 'package:notes/update/update_status.dart';

import '../../support/screenshot.dart';
import '../../update/world.dart';

void main() {
  setUpAll(loadAppFonts);

  late World world;
  late AppServices services;

  Future<void> createReady(WidgetTester tester) async {
    world = await World.create();
    services = AppServices.inMemory();
    addTearDown(() {
      world.dispose();
      services.close();
    });
    await tester.runAsync(() async {
      await world.publish();
      await world.controller.check();
      await world.controller.download();
    });
    expect(world.controller.status, isA<UpdateReadyToInstall>());
  }

  Future<void> pump(WidgetTester tester) async {
    await setWindow(tester, const Size(360, 760));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(services.settings),
        home: UpdatePromptShell(
          controller: world.controller,
          child: Scaffold(
            appBar: AppBar(title: const Text('Notes')),
            body: Center(
              child: TextField(
                key: const Key('editor-field'),
                decoration: const InputDecoration(
                  labelText: 'Synthetic editor',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('ready banner is absent until a verified update is ready', (
    tester,
  ) async {
    world = await World.create();
    services = AppServices.inMemory();
    addTearDown(() {
      world.dispose();
      services.close();
    });
    await pump(tester);
    expect(find.text('Update ready'), findsNothing);
    expect(find.byKey(const Key('editor-field')), findsOneWidget);
  });

  testWidgets('ready banner is accessible and leaves the editor usable', (
    tester,
  ) async {
    await createReady(tester);
    await pump(tester);
    expect(find.text('Update ready'), findsOneWidget);
    expect(find.text('Install now'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final banner = tester.getRect(find.text('Update ready'));
    final editor = tester.getRect(find.byKey(const Key('editor-field')));
    expect(editor.top, greaterThan(banner.top));
    final editorField = find.byKey(const Key('editor-field'));
    await tester.tap(editorField);
    await tester.pump();
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);
  });

  testWidgets('Later snoozes the banner while Updates still offers Install', (
    tester,
  ) async {
    await createReady(tester);
    await pump(tester);
    await tester.tap(find.text('Later'));
    await tester.pump();
    expect(find.text('Update ready'), findsNothing);
    expect(world.controller.status, isA<UpdateReadyToInstall>());

    final context = tester.element(find.byKey(const Key('editor-field')));
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => UpdatesScreen(
          controller: world.controller,
          settings: services.settings,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Install…'), findsOneWidget);
  });

  testWidgets('restoring ready state in a new launch shows the banner again', (
    tester,
  ) async {
    await createReady(tester);
    await pump(tester);
    world.controller.snoozeReadyPrompt();
    await tester.pump();
    expect(find.text('Update ready'), findsNothing);

    world.controller.dispose();
    world.controller = world.makeController();
    expect(await tester.runAsync(world.controller.restoreReady), isTrue);
    await pump(tester);
    expect(find.text('Update ready'), findsOneWidget);
  });

  testWidgets('Install now shows the existing confirmation before handoff', (
    tester,
  ) async {
    await createReady(tester);
    await pump(tester);
    await tester.tap(find.text('Install now'));
    await tester.pumpAndSettle();
    expect(find.text('Install version 1.0.1?'), findsOneWidget);
    expect(
      find.text(
        'Notes will close, update itself and reopen. Your notes '
        'are stored separately and are not touched.',
      ),
      findsOneWidget,
    );
  });
}
