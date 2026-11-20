import 'dart:math' as math;

import '../../data/models.dart';
import '../material.dart';
import '../theme/app_theme.dart';
import '../widgets/touch.dart';

const _chipFontSize = 13.0;
const _chipLineHeight = 1.2;

/// Height of a chip: 30 dp, growing with the text so large interface text is
/// never clipped.
double chipHeight(TextScaler scaler) =>
    math.max(30, scaler.scale(_chipFontSize) * _chipLineHeight + 12);

/// Height of the strip: the chip plus room to tap it, never under 44 dp (48 on
/// touch platforms).
double stripHeight(BuildContext context, TextScaler scaler) =>
    math.max(hitSize(context, desktop: 44), chipHeight(scaler) + 14);

/// Compact horizontally scrollable row of folder chips.
class FolderStrip extends StatelessWidget {
  const FolderStrip({
    super.key,
    required this.folders,
    required this.counts,
    required this.selectedId,
    required this.unfiledSelected,
    required this.inset,
    required this.onAll,
    required this.onFolder,
    required this.onUnfiled,
    required this.onNew,
    required this.onFolderMenu,
  });

  final List<Folder> folders;
  final LibraryCounts counts;
  final String? selectedId;
  final bool unfiledSelected;
  final double inset;
  final VoidCallback onAll;
  final ValueChanged<Folder> onFolder;
  final VoidCallback onUnfiled;
  final VoidCallback onNew;

  /// Called with the folder and the global position to open the menu at.
  final void Function(Folder folder, Offset position) onFolderMenu;

  @override
  Widget build(BuildContext context) {
    final showUnfiled =
        folders.isNotEmpty && (counts.unfiled > 0 || unfiledSelected);
    final chips = <Widget>[
      _Chip(
        label: 'All',
        count: counts.active,
        selected: selectedId == null && !unfiledSelected,
        onTap: onAll,
      ),
      for (final f in folders)
        _Chip(
          key: ValueKey('folder-${f.id}'),
          label: f.name,
          count: f.noteCount,
          selected: selectedId == f.id,
          onTap: () => onFolder(f),
          onMenu: (pos) => onFolderMenu(f, pos),
        ),
      if (showUnfiled)
        _Chip(
          label: 'Unfiled',
          count: counts.unfiled,
          selected: unfiledSelected,
          onTap: onUnfiled,
        ),
      _Chip(icon: Icons.add_rounded, tooltip: 'New folder', onTap: onNew),
    ];
    final scaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: stripHeight(context, scaler),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: inset),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) => chips[i],
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({
    super.key,
    this.label,
    this.count,
    this.icon,
    this.tooltip,
    this.selected = false,
    required this.onTap,
    this.onMenu,
  });

  final String? label;
  final int? count;
  final IconData? icon;
  final String? tooltip;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMenu;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final motion = AppMotion.of(context);
    final ring =
        _focus &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final fg = widget.selected ? p.accent : p.textMuted;
    final border = ring
        ? p.accent
        : widget.selected
        ? p.accent.withValues(alpha: 0.5)
        : _hover
        ? p.textFaint
        : p.cardBorder;
    final fill = widget.selected
        ? p.accent.withValues(alpha: 0.12)
        : Colors.transparent;

    Widget visual;
    if (widget.icon != null) {
      visual = Icon(widget.icon, size: 18, color: p.textMuted);
    } else {
      visual = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                widget.label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _chipFontSize,
                  height: _chipLineHeight,
                  fontWeight: widget.selected
                      ? FontWeight.w600
                      : FontWeight.w500,
                  color: widget.selected ? p.accent : p.text,
                ),
              ),
            ),
          ),
          if (widget.count != null) ...[
            const SizedBox(width: 6),
            Text(
              '${widget.count}',
              style: TextStyle(
                fontSize: 11.5,
                color: fg.withValues(alpha: 0.8),
              ),
            ),
          ],
        ],
      );
    }

    final chip = AnimatedContainer(
      duration: motion.fast,
      height: chipHeight(MediaQuery.textScalerOf(context)),
      padding: EdgeInsets.symmetric(horizontal: widget.icon != null ? 8 : 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: border, width: ring ? 1.5 : 1),
      ),
      child: visual,
    );

    void openMenu() {
      final box = context.findRenderObject()! as RenderBox;
      widget.onMenu!(
        box.localToGlobal(Offset(box.size.width / 2, box.size.height)),
      );
    }

    final target = InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onMenu == null ? null : openMenu,
      onSecondaryTapDown: widget.onMenu == null
          ? null
          : (d) => widget.onMenu!(d.globalPosition),
      onHover: (h) => setState(() => _hover = h),
      onFocusChange: (f) => setState(() => _focus = f),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
      child: SizedBox(
        width: widget.icon == null ? null : hitSize(context, desktop: 36),
        height: stripHeight(context, MediaQuery.textScalerOf(context)),
        child: Center(child: chip),
      ),
    );
    return widget.tooltip == null
        ? target
        : Tooltip(message: widget.tooltip!, child: target);
  }
}
