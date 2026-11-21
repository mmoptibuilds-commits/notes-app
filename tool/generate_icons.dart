// Generates the app icon at every size needed. Run with:
//   flutter test tool/generate_icons.dart
// Output is committed so builds do not depend on this step.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ui/brand_mark.dart';

Future<void> _png(
  String path,
  int size, {
  required bool background,
  bool rounded = false,
  double scale = 1,
}) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  final s = size.toDouble();
  if (background) {
    final paint = ui.Paint()..color = brandBackground;
    if (rounded) {
      c.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(0, 0, s, s),
          ui.Radius.circular(s * 0.22),
        ),
        paint,
      );
    } else {
      c.drawRect(ui.Rect.fromLTWH(0, 0, s, s), paint);
    }
  }
  paintNoteGlyph(c, s, scale: scale);
  final img = await rec.endRecording().toImage(size, size);
  final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes.buffer.asUint8List());
}

void main() {
  test('generate icons', () async {
    await _png(
      'assets/icon/icon_512.png',
      512,
      background: true,
      rounded: true,
    );
    await _png(
      'assets/icon/icon_1024.png',
      1024,
      background: true,
      rounded: true,
    );
    const res = 'android/app/src/main/res';
    // Legacy launcher icons.
    for (final (d, px) in [
      ('mdpi', 48),
      ('hdpi', 72),
      ('xhdpi', 96),
      ('xxhdpi', 144),
      ('xxxhdpi', 192),
    ]) {
      await _png(
        '$res/mipmap-$d/ic_launcher.png',
        px,
        background: true,
        rounded: true,
      );
    }
    // Adaptive icon foreground (108 dp canvas; glyph kept inside the safe zone).
    for (final (d, px) in [
      ('mdpi', 108),
      ('hdpi', 162),
      ('xhdpi', 216),
      ('xxhdpi', 324),
      ('xxxhdpi', 432),
    ]) {
      await _png(
        '$res/mipmap-$d/ic_launcher_foreground.png',
        px,
        background: false,
        scale: 0.72,
      );
    }
    Directory('$res/mipmap-anydpi-v26').createSync(recursive: true);
    File('$res/mipmap-anydpi-v26/ic_launcher.xml')
        .writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');
    Directory('$res/values').createSync(recursive: true);
    File('$res/values/ic_launcher_background.xml')
        .writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#000000</color>
</resources>
''');
  });
}
