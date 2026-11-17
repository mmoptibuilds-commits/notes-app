import '../material.dart';
import '../theme/app_theme.dart';
import 'dialogs.dart';

/// One compact menu entry: optional icon (or a check mark), label, and an
/// optional faint trailing text such as a count.
PopupMenuItem<T> menuItem<T>(
  BuildContext context,
  T value,
  String label, {
  IconData? icon,
  bool checked = false,
  bool reserveIcon = false,
  bool danger = false,
  String? trailing,
}) {
  final p = AppPalette.of(context);
  final color = danger ? p.danger : p.text;
  return PopupMenuItem<T>(
    value: value,
    height: 42,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (checked)
          Icon(Icons.check_rounded, size: 18, color: p.accent)
        else if (icon != null)
          Icon(icon, size: 18, color: danger ? p.danger : p.textMuted)
        else if (reserveIcon)
          const SizedBox(width: 18),
        if (checked || icon != null || reserveIcon) const SizedBox(width: 10),
        Flexible(
          child: Text(label, style: TextStyle(fontSize: 13.5, color: color)),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 16),
          Text(trailing, style: TextStyle(fontSize: 12, color: p.textFaint)),
        ],
      ],
    ),
  );
}

/// A small non-interactive heading inside a menu.
PopupMenuItem<T> menuLabel<T>(BuildContext context, String label) {
  final p = AppPalette.of(context);
  return PopupMenuItem<T>(
    enabled: false,
    height: 30,
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        color: p.textFaint,
      ),
    ),
  );
}

/// Opens [items] as a menu at a global [position] (right-click, long-press).
Future<T?> showContextMenu<T>(
  BuildContext context,
  Offset position,
  List<PopupMenuEntry<T>> items,
) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: items,
    popUpAnimationStyle: animationStyleOf(context),
  );
}
