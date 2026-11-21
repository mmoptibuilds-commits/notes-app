import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/models.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/library/move_dialog.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../../support/screenshot.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('Android move dialog rows are at least 48 dp high', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final services = AppServices.inMemory();
    addTearDown(services.close);
    await setWindow(tester, const Size(360, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(services.settings),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  await showMoveDialog(
                    context,
                    folders: const [
                      Folder(id: 'work', name: 'Work', noteCount: 2),
                    ],
                    currentIds: {null},
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final rows = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(InkWell),
    );
    expect(rows, findsNWidgets(3));
    for (var i = 0; i < rows.evaluate().length; i++) {
      expect(
        tester.getSize(rows.at(i)).height,
        greaterThanOrEqualTo(48),
        reason: 'move dialog row $i',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
