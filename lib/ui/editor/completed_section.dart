import '../../doc/checklist_projection.dart';
import '../material.dart';
import '../theme/app_theme.dart';

/// The collapsible list of checked items under a note's text.
///
/// Display only: the items stay in the stored document; this widget shows
/// their text and offers restore and delete.
class CompletedSection extends StatelessWidget {
  const CompletedSection({
    super.key,
    required this.items,
    required this.collapsed,
    required this.onToggle,
    required this.onRestore,
    required this.onDelete,
    required this.onRestoreAll,
    required this.onDeleteAll,
  });

  final List<CompletedLine> items;
  final bool collapsed;
  final VoidCallback onToggle;
  final ValueChanged<CompletedLine> onRestore;
  final ValueChanged<CompletedLine> onDelete;
  final VoidCallback onRestoreAll;
  final VoidCallback onDeleteAll;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final p = AppPalette.of(context);
    final motion = AppMotion.of(context);
    final n = items.length;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
        border: Border.all(color: p.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: collapsed ? 0 : 0.25,
                    duration: motion.fast,
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: p.textMuted,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$n completed ${n == 1 ? 'item' : 'items'}',
                      style: TextStyle(
                        color: p.textMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Uncheck all',
                    icon: const Icon(Icons.restart_alt_rounded, size: 19),
                    onPressed: onRestoreAll,
                  ),
                  IconButton(
                    tooltip: 'Delete completed items',
                    icon: Icon(
                      Icons.delete_sweep_outlined,
                      size: 19,
                      color: p.danger,
                    ),
                    onPressed: onDeleteAll,
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: motion.medium,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: collapsed
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Column(
                      children: [
                        for (final item in items)
                          _Row(
                            key: ValueKey(item.id),
                            item: item,
                            onRestore: () => onRestore(item),
                            onDelete: () => onDelete(item),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.item,
    required this.onRestore,
    required this.onDelete,
  });

  final CompletedLine item;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = item.text.trim();
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 2),
      child: Row(
        children: [
          Tooltip(
            message: 'Restore',
            child: InkResponse(
              onTap: onRestore,
              radius: 22,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(Icons.check_box_rounded, size: 20, color: p.accent),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text.isEmpty ? '(empty item)' : text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.textFaint,
                fontSize: 14,
                decoration: TextDecoration.lineThrough,
                decorationColor: p.textFaint,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Delete item',
            icon: Icon(Icons.close_rounded, size: 18, color: p.textFaint),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
