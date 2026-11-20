import '../material.dart';

/// Smallest comfortable touch target (Material guidance, 48 dp).
const touchTarget = 48.0;

/// Whether the app is running on a touch platform (phones and tablets).
/// Follows [ThemeData.platform], so tests can override it.
bool isTouchPlatform(BuildContext context) {
  final p = Theme.of(context).platform;
  return p == TargetPlatform.android || p == TargetPlatform.iOS;
}

/// A control's hit size: [touchTarget] on touch platforms, the more compact
/// [desktop] size with a mouse.
double hitSize(BuildContext context, {double desktop = 40}) =>
    isTouchPlatform(context) ? touchTarget : desktop;

/// Minimum button size: [hitSize] tall, so a button keeps its touch height
/// on phones even where a theme density would shrink it. Width is at least
/// [width] (the Material minimum), and labels may still grow the button.
Size touchButtonMinimumSize(
  BuildContext context, {
  double width = 64,
  double desktop = 40,
}) => Size(width, hitSize(context, desktop: desktop));

/// Density for a button on a touch platform. The app theme is compact, which
/// shrinks buttons by 8 dp and would undo [touchButtonMinimumSize]; phones
/// get standard density. Desktop keeps the theme's density (null).
VisualDensity? touchVisualDensity(BuildContext context) =>
    isTouchPlatform(context) ? VisualDensity.standard : null;
