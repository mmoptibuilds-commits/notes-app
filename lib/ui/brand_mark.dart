import 'dart:ui' as ui;

import 'material.dart';

/// Brand colours. The app icon, the splash and the launch screens all use
/// these, so the brand looks the same everywhere.
const brandBackground = ui.Color(0xFF000000);
const brandAccent = ui.Color(0xFFA8B1FF);

/// The note glyph centred in a square of side [s]. [scale] shrinks it (the
/// adaptive-icon safe zone is the middle 66%).
void paintNoteGlyph(
  ui.Canvas c,
  double s, {
  double scale = 1,
  ui.Color color = brandAccent,
}) {
  final g = s * 0.46 * scale; // sheet width
  final h = g * 1.28;
  final left = (s - g) / 2;
  final top = (s - h) / 2;
  final r = g * 0.16;
  final fold = g * 0.30;
  final stroke = g * 0.085;
  final p = ui.Paint()
    ..color = color
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

/// The note glyph as a widget, [size] logical pixels square.
class NoteGlyph extends StatelessWidget {
  const NoteGlyph({super.key, this.size = 96, this.color = brandAccent});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GlyphPainter(color));
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      paintNoteGlyph(canvas, size.shortestSide, color: color);

  @override
  bool shouldRepaint(_GlyphPainter old) => old.color != color;
}
