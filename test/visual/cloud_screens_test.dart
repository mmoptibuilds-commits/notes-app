import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/sync/cloud_screen.dart';
import 'package:notes/ui/theme/app_theme.dart';

import '../support/screenshot.dart';
import '../ui/sync/support.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('cloud sync phone and desktop review screenshots', (
    tester,
  ) async {
    final cases = [
      (CloudPhase.signedOut, const Size(412, 915), 'cloud_signed_out_phone'),
      (CloudPhase.signedIn, const Size(1280, 800), 'cloud_upload_desktop'),
      (CloudPhase.ready, const Size(412, 915), 'cloud_ready_phone'),
    ];
    for (final (phase, size, name) in cases) {
      final services = servicesWithCloud(phase: phase);
      services.settings.theme = AppTheme.charcoal;
      addTearDown(services.close);
      await setWindow(tester, size, pixelRatio: 1);
      await tester.pumpWidget(
        AppScope(
          services: services,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(services.settings),
            home: const CloudScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await screenshot(tester, name);
    }
  });
}
