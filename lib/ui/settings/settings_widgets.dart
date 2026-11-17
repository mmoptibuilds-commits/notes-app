import '../../app.dart';
import '../../data/app_settings.dart';
import '../material.dart';
import '../theme/app_theme.dart';
import '../widgets/dialogs.dart';

/// Rebuilds [builder] whenever a setting changes.
class SettingsBuilder extends StatelessWidget {
  const SettingsBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, AppSettings settings) builder;

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => builder(context, settings),
    );
  }
}

/// A titled group of rows on one bordered surface.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.rows});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                color: p.textMuted,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
              border: Border.all(color: p.cardBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: p.cardBorder),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A row: title (+ optional subtitle) on the left, [trailing] on the right,
/// optional [below] content full width under the title.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.below,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? below;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final head = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 14, color: p.text)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: p.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 28),
        child: below == null
            ? head
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [head, const SizedBox(height: 8), below!],
              ),
      ),
    );
    return onTap == null ? body : InkWell(onTap: onTap, child: body);
  }
}

/// A row that picks one value from a small set with a segmented control.
class SegmentedRow<T> extends StatelessWidget {
  const SegmentedRow({
    super.key,
    required this.title,
    required this.values,
    required this.labelOf,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final List<T> values;
  final String Function(T) labelOf;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => SettingsRow(
    title: title,
    below: Segmented<T>(
      values: values,
      labelOf: labelOf,
      value: value,
      onChanged: onChanged,
    ),
  );
}

class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.values,
    required this.labelOf,
    required this.value,
    required this.onChanged,
  });

  final List<T> values;
  final String Function(T) labelOf;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final motion = AppMotion.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.background,
        borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
        border: Border.all(color: p.cardBorder),
      ),
      child: Row(
        children: [
          for (final v in values)
            Expanded(
              child: Semantics(
                button: true,
                selected: v == value,
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => onChanged(v),
                  child: AnimatedContainer(
                    duration: motion.fast,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: v == value
                          ? p.accent.withValues(alpha: 0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      labelOf(v),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: v == value
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: v == value ? p.accent : p.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row that picks one value from a longer list in a popup menu.
class MenuRow<T> extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.title,
    required this.values,
    required this.labelOf,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final List<T> values;
  final String Function(T) labelOf;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return PopupMenuButton<T>(
      tooltip: title,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      popUpAnimationStyle: animationStyleOf(context),
      itemBuilder: (context) => [
        for (final v in values)
          PopupMenuItem<T>(
            value: v,
            height: 42,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: v == value
                      ? Icon(Icons.check_rounded, size: 18, color: p.accent)
                      : null,
                ),
                Text(
                  labelOf(v),
                  style: TextStyle(fontSize: 13.5, color: p.text),
                ),
              ],
            ),
          ),
      ],
      child: SettingsRow(
        title: title,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              labelOf(value),
              style: TextStyle(fontSize: 13.5, color: p.textMuted),
            ),
            const SizedBox(width: 4),
            Icon(Icons.unfold_more_rounded, size: 18, color: p.textFaint),
          ],
        ),
      ),
    );
  }
}

/// A row with a switch.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: SizedBox(
        height: 28,
        child: FittedBox(
          child: Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: p.onAccent,
            activeTrackColor: p.accent,
            inactiveThumbColor: p.textMuted,
            inactiveTrackColor: p.background,
            trackOutlineColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? p.accent : p.cardBorder,
            ),
          ),
        ),
      ),
    );
  }
}

/// A row with a slider and its current value as text.
class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.label,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return SettingsRow(
      title: title,
      trailing: Text(
        label,
        style: TextStyle(
          fontSize: 13.5,
          color: p.textMuted,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      below: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          activeTrackColor: p.accent,
          inactiveTrackColor: p.cardBorder,
          thumbColor: p.accent,
          overlayColor: p.accent.withValues(alpha: 0.12),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
          tickMarkShape: SliderTickMarkShape.noTickMark,
          showValueIndicator: ShowValueIndicator.never,
        ),
        child: SizedBox(
          height: 32,
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeStart: onChangeStart,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ),
    );
  }
}
