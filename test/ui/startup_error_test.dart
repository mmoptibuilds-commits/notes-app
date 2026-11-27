import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/ui/startup_error.dart';

void main() {
  testWidgets('too-new database error shows the backup and rollback steps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      StartupErrorApp(
        error: DatabaseTooNewException(6, 5, databasePath: '/tmp/notes.db'),
      ),
    );

    expect(find.text('This version of Notes is too old'), findsOneWidget);
    expect(find.textContaining('/tmp/notes.db.pre-v6.bak'), findsOneWidget);
    expect(find.textContaining('keep the current database'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('in-memory too-new error does not invent a backup path', (
    tester,
  ) async {
    await tester.pumpWidget(
      StartupErrorApp(error: DatabaseTooNewException(6, 5)),
    );

    expect(find.text('This version of Notes is too old'), findsOneWidget);
    expect(find.textContaining('pre-migration copy'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
