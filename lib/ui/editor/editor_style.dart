import 'package:flutter_quill/flutter_quill.dart';

import '../../data/app_settings.dart';
import '../material.dart';
import '../theme/app_theme.dart';

/// Quill text styles for the user's editor font, size and line height.
DefaultStyles buildEditorStyles(BuildContext context, AppSettings s) {
  final p = AppPalette.of(context);
  final size = s.editorFontSize;
  final base = TextStyle(
    fontFamily: s.editorFont.family,
    fontSize: size,
    height: s.editorLineHeight,
    color: p.text,
  );
  final mono = TextStyle(
    fontFamily: 'JetBrainsMono',
    fontSize: size * 0.88,
    height: 1.45,
    color: p.text,
  );
  const none = HorizontalSpacing(0, 0);
  const noLine = VerticalSpacing(0, 0);
  DefaultTextBlockStyle block(
    TextStyle style,
    double top,
    double bottom, {
    HorizontalSpacing h = none,
    BoxDecoration? decoration,
  }) => DefaultTextBlockStyle(
    style,
    h,
    VerticalSpacing(top, bottom),
    noLine,
    decoration,
  );
  TextStyle heading(double scale, FontWeight w) =>
      base.copyWith(fontSize: size * scale, fontWeight: w, height: 1.28);
  return DefaultStyles(
    paragraph: block(base, 0, 4),
    h1: block(heading(1.6, FontWeight.w700), 14, 4),
    h2: block(heading(1.32, FontWeight.w700), 12, 4),
    h3: block(heading(1.14, FontWeight.w600), 10, 3),
    placeHolder: block(base.copyWith(color: p.textFaint), 0, 0),
    bold: const TextStyle(fontWeight: FontWeight.w700),
    italic: const TextStyle(fontStyle: FontStyle.italic),
    underline: const TextStyle(decoration: TextDecoration.underline),
    strikeThrough: TextStyle(
      decoration: TextDecoration.lineThrough,
      decorationColor: p.textMuted,
    ),
    link: TextStyle(
      color: p.accent,
      decoration: TextDecoration.underline,
      decorationColor: p.accent.withValues(alpha: 0.5),
    ),
    inlineCode: InlineCodeStyle(
      style: mono.copyWith(fontSize: size * 0.86),
      backgroundColor: p.codeBackground,
      radius: const Radius.circular(4),
    ),
    lists: DefaultListBlockStyle(
      base,
      none,
      const VerticalSpacing(0, 2),
      noLine,
      null,
      null,
    ),
    quote: block(
      base.copyWith(color: p.textMuted),
      6,
      6,
      h: const HorizontalSpacing(12, 0),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: p.accent.withValues(alpha: 0.55), width: 3),
        ),
      ),
    ),
    code: block(
      mono,
      6,
      8,
      h: const HorizontalSpacing(10, 10),
      decoration: BoxDecoration(
        color: p.codeBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.cardBorder),
      ),
    ),
  );
}
