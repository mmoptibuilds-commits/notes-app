import '../material.dart';
import '../theme/app_theme.dart';
import '../widgets/menus.dart';
import '../widgets/touch.dart';

/// Square icon button: a 48 dp touch target on Android, 40 with a mouse.
class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.size,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final side = size ?? hitSize(context);
    return IconButton(
      icon: Icon(icon, size: 21),
      tooltip: tooltip,
      onPressed: onPressed,
      color: color,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      constraints: BoxConstraints.tightFor(width: side, height: side),
    );
  }
}

/// The search box: always visible on wide windows, behind an icon on phones.
class LibrarySearchField extends StatelessWidget {
  const LibrarySearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final side = hitSize(context);
    return SizedBox(
      height: side,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          onChanged: onChanged,
          onSubmitted: (_) => onSubmitted?.call(),
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Search notes',
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 19,
              color: p.textFaint,
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 38,
              minHeight: 38,
            ),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close_rounded, size: 17),
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints.tightFor(
                      width: side,
                      height: side,
                    ),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                      focusNode.requestFocus();
                    },
                  ),
            suffixIconConstraints: BoxConstraints(
              minWidth: side,
              minHeight: side,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 9),
          ),
        ),
      ),
    );
  }
}

/// One action in the selection bar.
class SelectionAction {
  const SelectionAction(
    this.icon,
    this.tooltip,
    this.onTap, {
    this.danger = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;
}

/// The header while notes are selected: count, select all, bulk actions.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.count,
    required this.inset,
    required this.onClose,
    required this.onSelectAll,
    required this.actions,
  });

  final int count;
  final double inset;
  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final List<SelectionAction> actions;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Container(
      height: 56,
      padding: EdgeInsets.symmetric(horizontal: inset - 8 < 0 ? 0 : inset - 8),
      decoration: BoxDecoration(
        color: p.raised,
        border: Border(bottom: BorderSide(color: p.cardBorder)),
      ),
      child: LayoutBuilder(
        builder: (context, cons) {
          // Each icon takes a hit size; the count needs room to read.
          final hit = hitSize(context, desktop: 40);
          final inlineNeeds = (actions.length + 2) * hit + _countMinWidth;
          final barWidth = cons.maxWidth;
          final inline = barWidth >= inlineNeeds;
          return Row(
            children: [
              HeaderIconButton(
                icon: Icons.close_rounded,
                tooltip: 'Clear selection',
                onPressed: onClose,
              ),
              Expanded(
                child: Text(
                  '$count selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
              ),
              HeaderIconButton(
                icon: Icons.select_all_rounded,
                tooltip: 'Select all',
                onPressed: onSelectAll,
              ),
              if (inline)
                for (final a in actions)
                  HeaderIconButton(
                    icon: a.icon,
                    tooltip: a.tooltip,
                    onPressed: a.onTap,
                    color: a.danger ? p.danger : null,
                  )
              else
                // Narrow windows: the actions move into one menu, so the
                // count stays readable and every action stays reachable.
                PopupMenuButton<int>(
                  tooltip: 'Selection actions',
                  icon: Icon(Icons.more_vert_rounded, color: p.text),
                  onSelected: (i) => actions[i].onTap(),
                  itemBuilder: (context) => [
                    for (var i = 0; i < actions.length; i++)
                      menuItem(
                        context,
                        i,
                        actions[i].tooltip,
                        icon: actions[i].icon,
                        danger: actions[i].danger,
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Room the selection count needs (e.g. "12 selected") beside the icons.
const _countMinWidth = 104.0;
