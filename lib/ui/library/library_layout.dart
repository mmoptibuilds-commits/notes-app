import 'dart:math' as math;

import '../material.dart';

/// Window width from which the desktop layout (visible search field) applies.
const wideBreakpoint = 720.0;

/// Widest a card gets before another column is added.
const maxCardWidth = 280.0;

/// Width cards aim for.
const targetCardWidth = 220.0;

/// Widest the single-column list gets on a large window.
const listMaxWidth = 760.0;

/// Gap between cards.
const cardGap = 8.0;

/// Horizontal padding of the page for a window of [width].
double pagePadding(double width) => width >= wideBreakpoint ? 16 : 12;

/// Number of card columns for a content area of [contentWidth]: aims for
/// ~[targetCardWidth] per card, at least 2, and never lets a card exceed
/// [maxCardWidth].
int columnCount(double contentWidth) {
  var cols = math.max(2, (contentWidth / targetCardWidth).round());
  while ((contentWidth - (cols - 1) * cardGap) / cols > maxCardWidth) {
    cols++;
  }
  return cols;
}

/// Horizontal inset of the page content. In list layout the content is
/// centred with a [listMaxWidth] column on wide windows.
double contentInset(double width, {required bool list}) {
  final pad = pagePadding(width);
  if (!list) return pad;
  return math.max(pad, (width - listMaxWidth) / 2);
}

/// Fixed card height for the uniform grid. Mirrors the card's own metrics so
/// the title (2 lines), [previewLines] of preview and the footer always fit,
/// at any interface text scale.
double gridCardExtent({
  required int previewLines,
  required TextScaler scaler,
  required bool tagRow,
}) {
  double line(double size, double height) => scaler.scale(size) * height;
  var h = 10.0 + 10.0; // padding
  h += line(14.5, 1.28) * 2; // title, 2 lines
  if (previewLines > 0) h += 5 + line(13, 1.35) * previewLines;
  h += 8 + line(11, 1.3); // footer
  h += 8; // progress line row
  if (tagRow) h += 6 + line(10.5, 1.3) + 5;
  return (h + 2).ceilToDouble();
}
