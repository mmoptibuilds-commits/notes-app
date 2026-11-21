import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/ui/library/library_layout.dart';
import 'package:notes/ui/material.dart';

import '../../support/screenshot.dart';
import 'support.dart';

/// The library must lay out without overflow or clipping at every window size
/// and text scale the app supports.
void main() {
  setUpAll(loadAppFonts);

  const sizes = <Size>[
    Size(320, 640),
    Size(360, 800),
    Size(412, 915),
    Size(915, 412),
    Size(768, 1024),
    Size(1024, 700),
    Size(1280, 800),
    Size(1920, 1080),
  ];
  const scales = <double>[1, 1.5, 2, 3];

  for (final size in sizes) {
    for (final scale in scales) {
      for (final layout in LibraryLayout.values) {
        testWidgets('${layout.name} lays out at ${size.width.toInt()}x'
            '${size.height.toInt()} scale $scale', (tester) async {
          final s = seedLibrary();
          addTearDown(s.services.close);
          markConflict(s, 'short');
          s.services.settings.layout = layout;
          s.services.settings.previewLines = 4;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearAllTestValues);
          await pumpLibrary(tester, s, size: size);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'library');

          // Near the top-left: at large scales a card can be taller than the window.
          await tester.longPressAt(
            tester.getTopLeft(noteItems().first) + const Offset(20, 20),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'selection');
          await tapTip(tester, 'Clear selection');

          final wide = size.width >= wideBreakpoint;
          if (!wide) {
            await tapTip(tester, 'Search');
          }
          await tester.enterText(find.byType(TextField), 'the');
          await tester.pump(const Duration(milliseconds: 150));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'search');
        });
      }
    }
  }

  // Overflow is not the only way to lose text: a fixed-height box can also
  // clip it without any error.
  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets('chips and title keep their text inside at scale $scale', (
      tester,
    ) async {
      final s = seedLibrary();
      addTearDown(s.services.close);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await pumpLibrary(tester, s, size: const Size(412, 915));
      await tester.pumpAndSettle();

      for (final label in ['All', 'Home']) {
        final chip = find.ancestor(
          of: find.text(label),
          matching: find.byType(AnimatedContainer),
        );
        // The label (13 dp scaled, at least one em tall) plus its padding.
        final box = tester.getRect(chip.first);
        expect(box.height, greaterThanOrEqualTo(13 * scale + 8), reason: label);
        // The strip leaves room to tap the chip.
        final strip = find.ancestor(
          of: chip.first,
          matching: find.byType(SizedBox),
        );
        expect(
          tester.getSize(strip.first).height,
          greaterThanOrEqualTo(box.height),
        );
      }
      // The heading sits in a 56 dp bar. A rect cannot show clipping (the
      // box clamps the text), so check the scale the title is drawn with.
      final text = tester.widget<Text>(find.text('All notes'));
      final scaler =
          text.textScaler ??
          MediaQuery.textScalerOf(tester.element(find.text('All notes')));
      expect(scaler.scale(22) * 1.2, lessThanOrEqualTo(56));
    });
  }

  // Linux is a first-class target: the same matrix with a mouse platform.
  for (final size in const [
    Size(800, 600),
    Size(1280, 800),
    Size(1920, 1080),
  ]) {
    for (final scale in const [1.0, 1.5]) {
      for (final layout in LibraryLayout.values) {
        testWidgets('Linux ${layout.name} lays out at ${size.width.toInt()}x'
            '${size.height.toInt()} scale $scale', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final s = seedLibrary();
          addTearDown(s.services.close);
          markConflict(s, 'short');
          s.services.settings.layout = layout;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearAllTestValues);
          await pumpLibrary(tester, s, size: size);
          await tester.pumpAndSettle();
          expect(noteItems(), findsWidgets);
          expect(tester.takeException(), isNull);
          await tester.enterText(find.byType(TextField), 'the');
          await tester.pump(const Duration(milliseconds: 150));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
