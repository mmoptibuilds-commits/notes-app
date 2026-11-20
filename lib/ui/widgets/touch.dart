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
