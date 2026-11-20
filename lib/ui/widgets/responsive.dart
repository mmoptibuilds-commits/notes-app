import 'dart:math' as math;

import '../material.dart';

/// Widest a single-column page body (Settings, Help, Sync, Data, toolbar
/// customisation) gets on a large window. Narrower windows use all the width
/// minus [pageMinGutter] on each side.
const pageMaxWidth = 640.0;

/// Narrowest gap kept between the window edge and page content.
const pageMinGutter = 12.0;

/// Horizontal gutter on each side of a body [maxWidth] wide inside a window of
/// [width]. Never less than [minGutter], so content never touches the edge.
double pageGutter(
  double width, {
  double maxWidth = pageMaxWidth,
  double minGutter = pageMinGutter,
}) => math.max(minGutter, (width - maxWidth) / 2);

/// Number of equal columns for [contentWidth] with [gap] between items.
///
/// Picks the most columns whose items still reach [minItemWidth]. Whenever
/// more than one column is returned, no item is wider than [maxItemWidth]:
/// columns are added until that holds, even if items then fall below the
/// minimum (the maximum is the one that keeps cards from stretching). One
/// column is returned when nothing else fits; the caller then caps or centres
/// that single item itself.
int columnsFor(
  double contentWidth, {
  required double minItemWidth,
  required double maxItemWidth,
  double gap = 8,
}) {
  if (contentWidth <= 0) return 1;
  // Most columns whose items still reach the minimum width.
  var cols = math.max(1, ((contentWidth + gap) / (minItemWidth + gap)).floor());
  // More columns if the items would otherwise exceed the maximum width.
  while (cols > 1 && (contentWidth - (cols - 1) * gap) / cols > maxItemWidth) {
    cols++;
  }
  return cols;
}

/// Centres [child] in a column no wider than [maxWidth]. Narrow windows keep
/// [minGutter] on each side. Use for any page that reads as one column of
/// rows or prose, so wide windows do not stretch it edge to edge.
class BoundedPage extends StatelessWidget {
  const BoundedPage({
    super.key,
    required this.child,
    this.maxWidth = pageMaxWidth,
    this.minGutter = pageMinGutter,
  });

  final Widget child;
  final double maxWidth;
  final double minGutter;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        final side = pageGutter(
          cons.maxWidth,
          maxWidth: maxWidth,
          minGutter: minGutter,
        );
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: child,
        );
      },
    );
  }
}
