// Generates the app icon at every size needed. Run with:
//   flutter test tool/generate_icons.dart
// Output is committed so builds do not depend on this step.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

const _bg = ui.Color(0xFF000000);
const _accent = ui.Color(0xFFA8B1FF);

/// The note glyph centred in a square of side [s]. [scale] shrinks it (the
/// adaptive-icon safe zone is the middle 66%).
void _glyph(ui.Canvas c, double s, {double scale = 1}) {
  final g = s * 0.46 * scale; // sheet width
  final h = g * 1.28;
  final left = (s - g) / 2;
  final top = (s - h) / 2;
  final r = g * 0.16;
  final fold = g * 0.30;
  final stroke = g * 0.085;
  final p = ui.Paint()
    ..color = _accent
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = stroke
    ..strokeJoin = ui.StrokeJoin.round
    ..strokeCap = ui.StrokeCap.round;
  // Sheet with a folded top-right corner.
  final path = ui.Path()
    ..moveTo(left + r, top)
    ..lineTo(left + g - fold, top)
    ..lineTo(left + g, top + fold)
    ..lineTo(left + g, top + h - r)
    ..quadraticBezierTo(left + g, top + h, left + g - r, top + h)
    ..lineTo(left + r, top + h)
    ..quadraticBezierTo(left, top + h, left, top + h - r)
    ..lineTo(left, top + r)
    ..quadraticBezierTo(left, top, left + r, top)
    ..close();
  c.drawPath(path, p);
  c.drawPath(
    ui.Path()
      ..moveTo(left + g - fold, top)
      ..lineTo(left + g - fold, top + fold)
      ..lineTo(left + g, top + fold),
    p,
  );
  // Text lines.
  final x0 = left + g * 0.2;
  for (var i = 0; i < 3; i++) {
    final y = top + h * (0.46 + i * 0.15);
    final x1 = left + g * (i == 2 ? 0.55 : 0.8);
    c.drawLine(ui.Offset(x0, y), ui.Offset(x1, y), p);
  }
}

Future<void> _png(String path, int size, {required bool background, bool rounded = false, double scale = 1}) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  final s = size.toDouble();
  if (background) {
    final paint = ui.Paint()..color = _bg;
    if (rounded) {
      c.drawRRect(ui.RRect.fromRectAndRadius(ui.Rect.fromLTWH(0, 0, s, s), ui.Radius.circular(s * 0.22)), paint);
    } else {
      c.drawRect(ui.Rect.fromLTWH(0, 0, s, s), paint);
    }
  }
  _glyph(c, s, scale: scale);
  final img = await rec.endRecording().toImage(size, size);
  final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes.buffer.asUint8List());
}

void main() {
  test('generate icons', () async {
    await _png('assets/icon/icon_512.png', 512, background: true, rounded: true);
    await _png('assets/icon/icon_1024.png', 1024, background: true, rounded: true);
    const res = 'android/app/src/main/res';
    // Legacy launcher icons.
    for (final (d, px) in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]) {
      await _png('$res/mipmap-$d/ic_launcher.png', px, background: true, rounded: true);
    }
    // Adaptive icon foreground (108 dp canvas; glyph kept inside the safe zone).
    for (final (d, px) in [('mdpi', 108), ('hdpi', 162), ('xhdpi', 216), ('xxhdpi', 324), ('xxxhdpi', 432)]) {
      await _png('$res/mipmap-$d/ic_launcher_foreground.png', px, background: false, scale: 0.72);
    }
    Directory('$res/mipmap-anydpi-v26').createSync(recursive: true);
    File('$res/mipmap-anydpi-v26/ic_launcher.xml').writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');
    Directory('$res/values').createSync(recursive: true);
    File('$res/values/ic_launcher_background.xml').writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#000000</color>
</resources>
''');
  });
}
