import '../material.dart';
import '../theme/app_theme.dart';

/// Square icon button with a guaranteed 44px touch target (40 on desktop).
class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.size = 44,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(icon, size: 21),
    tooltip: tooltip,
    onPressed: onPressed,
    color: color,
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.standard,
    constraints: BoxConstraints.tightFor(width: size, height: size),
  );
}

/// The search box: always visible on wide windows, behind an icon on phones.
class LibrarySearchField extends StatelessWidget {
  const LibrarySearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return SizedBox(
      height: 40,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          onChanged: onChanged,
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
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                      focusNode.requestFocus();
                    },
                  ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 38,
              minHeight: 38,
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
      child: Row(
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
          for (final a in actions)
            HeaderIconButton(
              icon: a.icon,
              tooltip: a.tooltip,
              onPressed: a.onTap,
              color: a.danger ? p.danger : null,
            ),
        ],
      ),
    );
  }
}
