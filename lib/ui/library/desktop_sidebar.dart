import '../../data/models.dart';
import '../../sync/sync_service.dart';
import '../material.dart';
import '../theme/app_theme.dart';

/// Width of the desktop sidebar.
const sidebarWidth = 232.0;

/// Persistent navigation for desktop windows: new note, all notes, folders,
/// Archive and Trash, and Sync / Settings at the bottom. Built from callbacks
/// like [FolderStrip]; it holds no state of its own beyond hover.
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.folders,
    required this.counts,
    required this.scope,
    required this.folderId,
    required this.unfiled,
    required this.unfiledStartup,
    required this.sync,
    required this.onNewNote,
    required this.onAll,
    required this.onFolder,
    required this.onUnfiled,
    required this.onScope,
    required this.onNewFolder,
    required this.onFolderMenu,
    required this.onSync,
    required this.onSettings,
    required this.onHelp,
  });

  final List<Folder> folders;
  final LibraryCounts counts;
  final NoteScope scope;
  final String? folderId;
  final bool unfiled;
  final bool unfiledStartup;

  /// Null when this build has no sync (the row is then hidden).
  final SyncService? sync;
  final VoidCallback onNewNote;
  final VoidCallback onAll;
  final ValueChanged<Folder> onFolder;
  final VoidCallback onUnfiled;
  final ValueChanged<NoteScope> onScope;
  final VoidCallback onNewFolder;
  final void Function(Folder folder, Offset position) onFolderMenu;
  final VoidCallback onSync;
  final VoidCallback onSettings;
  final VoidCallback onHelp;

  /// The tone of the sidebar: a touch off the page background.
  static Color surface(AppPalette p) =>
      Color.alphaBlend(p.text.withValues(alpha: 0.03), p.background);

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final showUnfiled =
        folders.isNotEmpty && (counts.unfiled > 0 || unfiled || unfiledStartup);
    final inActive = scope == NoteScope.active;
    return Container(
      width: sidebarWidth,
      decoration: BoxDecoration(
        color: surface(p),
        border: Border(right: BorderSide(color: p.cardBorder)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
              child: Text(
                'Notes',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: p.text,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _NewNoteButton(onPressed: onNewNote),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                children: [
                  _NavItem(
                    icon: Icons.notes_rounded,
                    label: 'All notes',
                    count: counts.active,
                    selected: inActive && folderId == null && !unfiled,
                    onTap: onAll,
                  ),
                  if (showUnfiled)
                    _NavItem(
                      icon: Icons.folder_off_outlined,
                      label: 'Unfiled',
                      count: counts.unfiled,
                      selected: inActive && unfiled,
                      onTap: onUnfiled,
                    ),
                  _SectionHeader(
                    label: 'Folders',
                    action: IconButton(
                      tooltip: 'New folder',
                      onPressed: onNewFolder,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      color: p.textMuted,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                    ),
                  ),
                  for (final f in folders)
                    _NavItem(
                      key: ValueKey('side-folder-${f.id}'),
                      icon: Icons.folder_outlined,
                      selectedIcon: Icons.folder_rounded,
                      label: f.name,
                      count: f.noteCount,
                      selected: inActive && folderId == f.id,
                      onTap: () => onFolder(f),
                      onMenu: (pos) => onFolderMenu(f, pos),
                    ),
                  if (folders.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
                      child: Text(
                        'No folders yet',
                        style: TextStyle(fontSize: 12.5, color: p.textFaint),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Divider(height: 1, color: p.cardBorder),
                  const SizedBox(height: 10),
                  if (counts.conflicts > 0)
                    _NavItem(
                      icon: Icons.call_split_rounded,
                      label: 'Conflicts',
                      count: counts.conflicts,
                      selected: scope == NoteScope.conflicts,
                      onTap: () => onScope(NoteScope.conflicts),
                    ),
                  _NavItem(
                    icon: Icons.archive_outlined,
                    selectedIcon: Icons.archive_rounded,
                    label: 'Archive',
                    count: counts.archived,
                    selected: scope == NoteScope.archived,
                    onTap: () => onScope(NoteScope.archived),
                  ),
                  _NavItem(
                    icon: Icons.delete_outline_rounded,
                    selectedIcon: Icons.delete_rounded,
                    label: 'Trash',
                    count: counts.trash,
                    selected: scope == NoteScope.trash,
                    onTap: () => onScope(NoteScope.trash),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.cardBorder),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
              child: Column(
                children: [
                  if (sync != null)
                    ListenableBuilder(
                      listenable: sync!,
                      builder: (context, _) {
                        final n = sync!.peers.list().length;
                        return _NavItem(
                          icon: Icons.sync_rounded,
                          label: 'Sync',
                          trailingText: sync!.syncing
                              ? 'Syncing…'
                              : n == 0
                              ? 'Not paired'
                              : '$n paired',
                          selected: false,
                          onTap: onSync,
                        );
                      },
                    ),
                  _NavItem(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    selected: false,
                    onTap: onSettings,
                  ),
                  _NavItem(
                    icon: Icons.help_outline_rounded,
                    label: 'Help',
                    selected: false,
                    onTap: onHelp,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewNoteButton extends StatelessWidget {
  const _NewNoteButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Tooltip(
      message: 'New note (Ctrl+N)',
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.add_rounded, size: 20),
        label: const Text('New note'),
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          minimumSize: const Size.fromHeight(40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          textStyle: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.action});

  final String label;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 0, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: p.textFaint,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    super.key,
    required this.icon,
    this.selectedIcon,
    required this.label,
    this.count,
    this.trailingText,
    required this.selected,
    required this.onTap,
    this.onMenu,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final int? count;
  final String? trailingText;
  final bool selected;
  final VoidCallback onTap;

  /// Right-click / long-press menu (folders).
  final ValueChanged<Offset>? onMenu;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final motion = AppMotion.of(context);
    final ring =
        _focus &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final sel = widget.selected;
    final fill = sel
        ? p.accent.withValues(alpha: 0.14)
        : _hover
        ? p.text.withValues(alpha: 0.05)
        : Colors.transparent;
    final count = widget.count;
    final trailing = widget.trailingText;

    Widget? tail;
    if (widget.onMenu != null && (_hover || _focus)) {
      tail = Builder(
        builder: (context) => InkResponse(
          onTap: () {
            final box = context.findRenderObject()! as RenderBox;
            widget.onMenu!(box.localToGlobal(box.size.center(Offset.zero)));
          },
          radius: 14,
          child: Tooltip(
            message: 'Folder options',
            child: Icon(Icons.more_horiz_rounded, size: 18, color: p.textMuted),
          ),
        ),
      );
    } else if (trailing != null) {
      tail = Text(
        trailing,
        style: TextStyle(fontSize: 11.5, color: p.textFaint),
      );
    } else if (count != null && count > 0) {
      tail = Text(
        '$count',
        style: TextStyle(fontSize: 12, color: sel ? p.accent : p.textFaint),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Semantics(
        selected: sel,
        button: true,
        child: AnimatedContainer(
          duration: motion.fast,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: ring ? p.accent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: InkWell(
            onTap: widget.onTap,
            onLongPress: widget.onMenu == null
                ? null
                : () {
                    final box = context.findRenderObject()! as RenderBox;
                    widget.onMenu!(
                      box.localToGlobal(Offset(box.size.width / 2, 20)),
                    );
                  },
            onSecondaryTapDown: widget.onMenu == null
                ? null
                : (d) => widget.onMenu!(d.globalPosition),
            onHover: (h) => setState(() => _hover = h),
            onFocusChange: (f) => setState(() => _focus = f),
            borderRadius: BorderRadius.circular(8),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      sel ? (widget.selectedIcon ?? widget.icon) : widget.icon,
                      size: 18,
                      color: sel ? p.accent : p.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                          color: p.text,
                        ),
                      ),
                    ),
                    if (tail != null) ...[const SizedBox(width: 8), tail],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
