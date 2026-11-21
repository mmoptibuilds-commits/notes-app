import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ui/brand_mark.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/splash.dart';

import '../../support/screenshot.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('splash shows until startup completes, then the app', (
    tester,
  ) async {
    final done = Completer<Widget>();
    await tester.pumpWidget(
      RepaintBoundary(child: Launcher(start: () => done.future)),
    );
    expect(find.byType(NoteGlyph), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    await setWindow(tester, const Size(1280, 800), pixelRatio: 1);
    await tester.pump();
    await screenshot(tester, 'splash-desktop');

    done.complete(const MaterialApp(home: Scaffold(body: Text('app ready'))));
    await tester.pumpAndSettle();
    expect(find.text('app ready'), findsOneWidget);
    expect(find.byType(SplashScreen), findsNothing);
  });

  testWidgets('a startup failure still replaces the splash', (tester) async {
    await tester.pumpWidget(
      Launcher(
        start: () async => const MaterialApp(home: Text('startup error')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('startup error'), findsOneWidget);
  });
}
