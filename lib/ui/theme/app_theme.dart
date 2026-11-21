import '../../data/app_settings.dart';
import '../material.dart';

/// Colours and measures that Material's [ColorScheme] has no slot for.
/// Read with `AppPalette.of(context)`.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.background,
    required this.card,
    required this.cardBorder,
    required this.raised,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.onAccent,
    required this.danger,
    required this.codeBackground,
  });

  /// Window / page background.
  final Color background;

  /// Note cards and grouped rows.
  final Color card;

  /// Hairline around cards; also dividers.
  final Color cardBorder;

  /// Menus, dialogs, sheets, the toolbar.
  final Color raised;
  final Color text;

  /// Secondary text: previews, dates.
  final Color textMuted;

  /// Tertiary text: hints, counters, disabled.
  final Color textFaint;
  final Color accent;
  final Color onAccent;
  final Color danger;
  final Color codeBackground;

  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>()!;

  static const amoled = AppPalette(
    background: Color(0xFF000000),
    card: Color(0xFF0E0E10),
    cardBorder: Color(0xFF323239),
    raised: Color(0xFF151518),
    text: Color(0xFFECECEF),
    textMuted: Color(0xFF9A9AA3),
    textFaint: Color(0xFF8A8A93),
    accent: Color(0xFFA8B1FF),
    onAccent: Color(0xFF0B0D24),
    danger: Color(0xFFFF6B62),
    codeBackground: Color(0xFF141417),
  );

  static const charcoal = AppPalette(
    background: Color(0xFF131316),
    card: Color(0xFF1C1C20),
    cardBorder: Color(0xFF38383E),
    raised: Color(0xFF222227),
    text: Color(0xFFE9E9EC),
    textMuted: Color(0xFFA0A0A9),
    textFaint: Color(0xFF8A8A93),
    accent: Color(0xFFA8B1FF),
    onAccent: Color(0xFF0B0D24),
    danger: Color(0xFFFF6B62),
    codeBackground: Color(0xFF19191D),
  );

  static const light = AppPalette(
    background: Color(0xFFF7F7F5),
    card: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFCBCBC7),
    raised: Color(0xFFFFFFFF),
    text: Color(0xFF1B1B1F),
    textMuted: Color(0xFF62626B),
    textFaint: Color(0xFF6F6F78),
    accent: Color(0xFF4A55C8),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFC62F25),
    codeBackground: Color(0xFFF0F0EC),
  );

  static AppPalette forTheme(AppTheme t) => switch (t) {
    AppTheme.amoled => amoled,
    AppTheme.charcoal => charcoal,
    AppTheme.light => light,
  };

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      background: c(background, other.background),
      card: c(card, other.card),
      cardBorder: c(cardBorder, other.cardBorder),
      raised: c(raised, other.raised),
      text: c(text, other.text),
      textMuted: c(textMuted, other.textMuted),
      textFaint: c(textFaint, other.textFaint),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      danger: c(danger, other.danger),
      codeBackground: c(codeBackground, other.codeBackground),
    );
  }
}

/// Spacing and shape constants shared by every screen.
abstract final class AppMetrics {
  static const cardRadius = 14.0;
  static const controlRadius = 10.0;
  static const cardPadding = EdgeInsets.fromLTRB(12, 10, 12, 10);
  static const gridGap = 8.0;
  static const pagePadding = 12.0;

  /// Widest a note's text column gets on a large window.
  static const editorMaxWidth = 760.0;
}

/// Durations scaled by the user's animation setting.
class AppMotion {
  const AppMotion(this.level);
  final AnimationLevel level;

  static AppMotion of(BuildContext context) =>
      Theme.of(context).extension<_MotionExt>()!.motion;

  double get _factor => switch (level) {
    AnimationLevel.off => 0,
    AnimationLevel.reduced => 0.5,
    AnimationLevel.full => 1,
  };

  bool get enabled => level != AnimationLevel.off;

  /// Small state changes: hover, selection, chips.
  Duration get fast => Duration(milliseconds: (120 * _factor).round());

  /// Expanding sections, layout changes.
  Duration get medium => Duration(milliseconds: (220 * _factor).round());

  /// Page transitions.
  Duration get page => Duration(milliseconds: (260 * _factor).round());
}

class _MotionExt extends ThemeExtension<_MotionExt> {
  const _MotionExt(this.motion);
  final AppMotion motion;
  @override
  _MotionExt copyWith() => this;
  @override
  _MotionExt lerp(_MotionExt? other, double t) => other ?? this;
}

class _NoTransitions extends PageTransitionsBuilder {
  const _NoTransitions();
  @override
  Widget buildTransitions<T>(route, context, animation, secondary, child) =>
      child;
}

class _FadeTransitions extends PageTransitionsBuilder {
  const _FadeTransitions();
  @override
  Widget buildTransitions<T>(route, context, animation, secondary, child) =>
      FadeTransition(opacity: animation, child: child);
}

/// The app theme for the user's current settings.
ThemeData buildTheme(AppSettings s) {
  final p = AppPalette.forTheme(s.theme);
  final dark = s.theme != AppTheme.light;
  final motion = AppMotion(s.animations);
  final scheme = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accent,
    onSecondary: p.onAccent,
    error: p.danger,
    onError: dark ? const Color(0xFF1B0503) : Colors.white,
    surface: p.background,
    onSurface: p.text,
    onSurfaceVariant: p.textMuted,
    outline: p.textFaint,
    outlineVariant: p.cardBorder,
    surfaceContainerLowest: p.background,
    surfaceContainerLow: p.card,
    surfaceContainer: p.card,
    surfaceContainerHigh: p.raised,
    surfaceContainerHighest: p.raised,
    surfaceTint: Colors.transparent,
    inverseSurface: p.text,
    onInverseSurface: p.background,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: s.uiFont.family,
    scaffoldBackgroundColor: p.background,
    canvasColor: p.background,
    visualDensity: VisualDensity.compact,
    splashFactory: motion.enabled
        ? InkSparkle.splashFactory
        : NoSplash.splashFactory,
  );
  final pageBuilder = switch (s.animations) {
    AnimationLevel.off => const _NoTransitions(),
    AnimationLevel.reduced => const _FadeTransitions(),
    AnimationLevel.full => null,
  };
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
    side: BorderSide(color: p.cardBorder),
  );
  return base.copyWith(
    extensions: [p, _MotionExt(motion)],
    pageTransitionsTheme: pageBuilder == null
        ? const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.linux: _FadeTransitions(),
            },
          )
        : PageTransitionsTheme(
            builders: {for (final t in TargetPlatform.values) t: pageBuilder},
          ),
    textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 12,
      toolbarHeight: 52,
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        color: p.text,
        fontWeight: FontWeight.w600,
        fontFamily: s.uiFont.family,
      ),
    ),
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: shape,
    ),
    dividerTheme: DividerThemeData(color: p.cardBorder, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.textMuted, size: 20),
    dialogTheme: DialogThemeData(
      backgroundColor: p.raised,
      elevation: 0,
      shape: shape,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.raised,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        side: BorderSide(color: p.cardBorder),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.raised,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
        side: BorderSide(color: p.cardBorder),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.raised),
        elevation: const WidgetStatePropertyAll(3),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
            side: BorderSide(color: p.cardBorder),
          ),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.raised,
      contentTextStyle: TextStyle(color: p.text, fontFamily: s.uiFont.family),
      actionTextColor: p.accent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
        side: BorderSide(color: p.cardBorder),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.accent,
      foregroundColor: p.onAccent,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      isDense: true,
      filled: true,
      fillColor: p.card,
      hintStyle: TextStyle(color: p.textFaint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
        borderSide: BorderSide(color: p.cardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
        borderSide: BorderSide(color: p.cardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
        borderSide: BorderSide(color: p.accent),
      ),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      iconColor: p.textMuted,
      textColor: p.text,
      horizontalTitleGap: 12,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.cardBorder),
      ),
      textStyle: TextStyle(color: p.text, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(p.textFaint.withValues(alpha: 0.5)),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: 0.3),
      selectionHandleColor: p.accent,
    ),
  );
}
