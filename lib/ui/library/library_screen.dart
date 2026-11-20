import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../app.dart';
import '../../data/app_settings.dart';
import '../../data/models.dart';
import '../../data/note_repository.dart';
import '../editor/editor_screen.dart';
import '../material.dart';
import '../settings/settings_screen.dart';
import '../shortcuts/shortcut_defs.dart';
import '../shortcuts/shortcut_guards.dart';
import '../theme/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/format.dart';
import '../widgets/menus.dart';
import '../widgets/touch.dart';
import 'folder_strip.dart';
import 'library_controller.dart';
import 'library_header.dart';
import 'library_layout.dart';
import 'move_dialog.dart';
import 'note_card.dart';

/// The home screen: folders, notes in three layouts, search, selection.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  LibraryController? _ctl;
  final _scroll = ScrollController();
  final _offsets = <String, double>{};
  final _searchCtl = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'library search');
  final _rootFocus = FocusNode(debugLabel: 'library', skipTraversal: true);
  Timer? _debounce;
  bool _searchOpen = false;
  String _lastKey = '';
  String _lastQuery = '';

  LibraryController get _c => _ctl!;
  NoteRepository get _repo => AppScope.of(context).notes;
  AppSettings get _settings => AppScope.of(context).settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ctl == null) {
      final s = AppScope.of(context);
      _ctl = LibraryController(s.notes, s.settings)..addListener(_onCtl);
      _lastKey = _ctl!.viewKey;
    }
    final route = ModalRoute.of(context);
    final covered = route != null && !route.isCurrent;
    final wasCovered = _c.covered;
    _c.setCovered(covered);
    if (wasCovered && !covered) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && FocusManager.instance.primaryFocus == null) {
          _rootFocus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl?.removeListener(_onCtl);
    _ctl?.dispose();
    _scroll.dispose();
    _searchCtl.dispose();
    _searchFocus.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- state

  void _onCtl() {
    final key = _c.viewKey;
    if (key != _lastKey) {
      if (_scroll.hasClients) _offsets[_lastKey] = _scroll.offset;
      _lastKey = key;
      _restoreOffset(_offsets[key] ?? 0);
    } else if (_c.searching && _c.query != _lastQuery) {
      _restoreOffset(0);
    } else if (_scroll.hasClients) {
      _holdOffset(_scroll.offset);
    }
    _lastQuery = _c.query;
    if (mounted) setState(() {});
  }

  /// After a reload in the same view, a lazy sliver may lay out from scratch
  /// and correct the offset to something earlier. Walk back to [keep] in
  /// viewport-sized steps unless the user has moved meanwhile.
  void _holdOffset(double keep) {
    var tries = 0;
    void check() {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.isScrollingNotifier.value || pos.pixels == keep) return;
      if (++tries > 40) return;
      final step = pos.viewportDimension * 0.8;
      final next = keep > pos.pixels
          ? (pos.pixels + step < keep ? pos.pixels + step : keep)
          : keep;
      pos.jumpTo(next);
      WidgetsBinding.instance.addPostFrameCallback((_) => check());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => check());
  }

  /// Puts the scroll view back to [target] once the new content is laid out.
  void _restoreOffset(double target) {
    void jump() {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      pos.jumpTo(target.clamp(0, pos.maxScrollExtent).toDouble());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      jump();
      WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    });
  }

  bool get _wide => MediaQuery.sizeOf(context).width >= wideBreakpoint;

  // --------------------------------------------------------------- search

  void _onQueryChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty && !_c.searching) return;
    _debounce = Timer(
      const Duration(milliseconds: 120),
      () => _c.setQuery(text),
    );
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _focusSearch() {
    if (_wide) {
      _searchFocus.requestFocus();
      _searchCtl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchCtl.text.length,
      );
    } else {
      _openSearch();
    }
  }

  void _closeSearch() {
    _debounce?.cancel();
    _searchCtl.clear();
    _c.setQuery('');
    if (_searchOpen) setState(() => _searchOpen = false);
    _rootFocus.requestFocus();
  }

  bool get _hasSearch =>
      _searchOpen || _c.searching || _searchCtl.text.isNotEmpty;

  // ------------------------------------------------------------ navigation

  void _go(NoteScope scope) {
    _debounce?.cancel();
    _searchCtl.clear();
    if (_searchOpen) setState(() => _searchOpen = false);
    _c.setScope(scope);
  }

  void _pickFolder({String? id, bool unfiled = false}) {
    _debounce?.cancel();
    _searchCtl.clear();
    if (_searchOpen) setState(() => _searchOpen = false);
    _c.selectFolder(id: id, unfiled: unfiled);
  }

  /// Backs out of one level: selection, then search, then a sub-view.
  /// Returns false when there was nothing to leave.
  bool _unwind() {
    if (_c.selecting) {
      _c.clearSelection();
      return true;
    }
    if (_hasSearch) {
      _closeSearch();
      return true;
    }
    if (_c.scope != NoteScope.active) {
      _go(NoteScope.active);
      return true;
    }
    return false;
  }

  void _newNote() => openEditor(context, folderId: _c.folderId);

  void _openSettings() => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

  // ---------------------------------------------------------- item events

  bool get _modifierHeld =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  void _onTap(NoteSummary n) {
    if (_c.selecting || _modifierHeld) {
      _c.toggle(n.id);
    } else {
      openEditor(context, noteId: n.id, folderId: n.folderId);
    }
  }

  void _onLongPress(NoteSummary n) {
    HapticFeedback.selectionClick();
    if (_c.selecting) {
      _c.toggle(n.id);
    } else {
      _c.selectOnly(n.id);
    }
  }

  Future<void> _onMenu(NoteSummary n, Offset pos) async {
    final scope = _c.scope;
    final choice = await showContextMenu<String>(context, pos, [
      menuItem(context, 'open', 'Open', icon: Icons.open_in_new_rounded),
      menuItem(context, 'select', 'Select', icon: Icons.check_circle_outline),
      if (scope == NoteScope.trash) ...[
        menuItem(context, 'restore', 'Restore', icon: Icons.restore_rounded),
        menuItem(
          context,
          'purge',
          'Delete forever',
          icon: Icons.delete_forever_outlined,
          danger: true,
        ),
      ] else ...[
        if (scope == NoteScope.conflicts)
          menuItem(
            context,
            'keep',
            'Keep as separate note',
            icon: Icons.call_split_rounded,
          ),
        menuItem(
          context,
          'pin',
          n.pinned ? 'Unpin' : 'Pin',
          icon: n.pinned ? Icons.push_pin : Icons.push_pin_outlined,
        ),
        menuItem(
          context,
          'archive',
          n.archived ? 'Unarchive' : 'Archive',
          icon: n.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
        ),
        menuItem(
          context,
          'move',
          'Move to folder…',
          icon: Icons.drive_file_move_outlined,
        ),
        menuItem(
          context,
          'trash',
          'Move to Trash',
          icon: Icons.delete_outline_rounded,
          danger: true,
        ),
      ],
    ]);
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'open':
        openEditor(context, noteId: n.id, folderId: n.folderId);
      case 'select':
        _c.selectOnly(n.id);
      default:
        await _apply(choice, [n]);
    }
  }

  // -------------------------------------------------------------- actions

  Future<void> _apply(String action, List<NoteSummary> ns) async {
    if (ns.isEmpty) return;
    final ids = [for (final n in ns) n.id];
    switch (action) {
      case 'pin':
        _repo.setPinned(ids, !ns.every((n) => n.pinned));
      case 'archive':
        final archive = !ns.every((n) => n.archived);
        _repo.setArchived(ids, archive);
        if (mounted) {
          showUndoSnack(
            context,
            '${archive ? 'Archived' : 'Unarchived'} ${notesCount(ids.length)}',
            () => _repo.setArchived(ids, !archive),
          );
        }
      case 'trash':
        _repo.trash(ids);
        if (mounted) {
          showUndoSnack(
            context,
            'Moved ${notesCount(ids.length)} to Trash',
            () => _repo.restore(ids),
          );
        }
      case 'restore':
        _repo.restore(ids);
        if (mounted) {
          showUndoSnack(
            context,
            'Restored ${notesCount(ids.length)}',
            () => _repo.trash(ids),
          );
        }
      case 'purge':
        final ok = await confirmDialog(
          context,
          title: 'Delete ${notesCount(ids.length)} forever?',
          message: 'This cannot be undone.',
          confirmLabel: 'Delete forever',
          destructive: true,
        );
        if (!ok) return;
        _repo.purge(ids);
      case 'keep':
        _repo.keepConflictCopy(ids);
        if (mounted) {
          showInfoSnack(context, 'Kept ${notesCount(ids.length)} as separate');
        }
      case 'move':
        await _move(ns);
    }
    if (mounted) {
      _c.clearSelection();
      _rootFocus.requestFocus();
    }
  }

  Future<void> _move(List<NoteSummary> ns) async {
    final choice = await showMoveDialog(
      context,
      folders: _c.folders,
      currentIds: {for (final n in ns) n.folderId},
    );
    if (choice == null || !mounted) return;
    final ids = [for (final n in ns) n.id];
    switch (choice) {
      case MoveToFolder(:final folderId):
        _repo.moveToFolder(ids, folderId);
      case MoveToNewFolder():
        final name = await promptDialog(
          context,
          title: 'New folder',
          hint: 'Folder name',
          confirmLabel: 'Create',
        );
        if (name == null) return;
        _repo.moveToFolder(ids, _repo.createFolder(name).id);
    }
  }

  Future<void> _emptyTrash() async {
    final n = _c.counts.trash;
    if (n == 0) return;
    final ok = await confirmDialog(
      context,
      title: 'Empty Trash?',
      message:
          '${notesCount(n)} will be deleted forever. This cannot be undone.',
      confirmLabel: 'Empty Trash',
      destructive: true,
    );
    if (ok) _repo.emptyTrash();
    if (mounted) _rootFocus.requestFocus();
  }

  Future<void> _newFolder() async {
    final name = await promptDialog(
      context,
      title: 'New folder',
      hint: 'Folder name',
      confirmLabel: 'Create',
    );
    if (name == null) return;
    _pickFolder(id: _repo.createFolder(name).id);
  }

  Future<void> _folderMenu(Folder f, Offset pos) async {
    final choice = await showContextMenu<String>(context, pos, [
      menuItem(context, 'rename', 'Rename', icon: Icons.edit_outlined),
      menuItem(
        context,
        'delete',
        'Delete folder',
        icon: Icons.delete_outline_rounded,
        danger: true,
      ),
    ]);
    if (!mounted || choice == null) return;
    if (choice == 'rename') {
      final name = await promptDialog(
        context,
        title: 'Rename folder',
        initial: f.name,
        confirmLabel: 'Rename',
      );
      if (name != null) _repo.renameFolder(f.id, name);
    } else {
      final ok = await confirmDialog(
        context,
        title: 'Delete "${f.name}"?',
        message: 'The notes in it are kept and move to Unfiled.',
        confirmLabel: 'Delete folder',
        destructive: true,
      );
      if (ok) _repo.deleteFolder(f.id);
    }
  }

  // ------------------------------------------------------------- keyboard

  void _escape() {
    switch (resolveEscape(
      popupOpen: false,
      hasSearch: _hasSearch,
      selecting: _c.selecting,
      searchFocused: _searchFocus.hasFocus,
      canGoBack: _c.scope != NoteScope.active,
    )) {
      case EscapeOutcome.clearSearch:
        _closeSearch();
      case EscapeOutcome.clearSelection:
        _c.clearSelection();
      case EscapeOutcome.unfocusSearch:
        _rootFocus.requestFocus();
      case EscapeOutcome.back:
        _go(NoteScope.active);
      case EscapeOutcome.closePopup:
      case EscapeOutcome.unhandled:
        break;
    }
  }

  Map<ShortcutId, VoidCallback> get _shortcutHandlers => {
    ShortcutId.newNote: _newNote,
    ShortcutId.focusSearch: _focusSearch,
    ShortcutId.slashSearch: _focusSearch,
    ShortcutId.selectAll: _c.selectAll,
    ShortcutId.trashSelected: () {
      if (_c.selecting) {
        _apply(
          _c.scope == NoteScope.trash ? 'purge' : 'trash',
          _c.selectedNotes,
        );
      }
    },
    ShortcutId.backToAllNotes: () {
      if (_c.scope != NoteScope.active) _go(NoteScope.active);
    },
    ShortcutId.openSettings: _openSettings,
    ShortcutId.openHelp: () => openHelp(context),
    ShortcutId.escape: _escape,
  };

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final c = _c;
    final canPop = !(c.selecting || _hasSearch || c.scope != NoteScope.active);
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _unwind();
      },
      child: shortcutScope(
        scopes: const {ShortcutScope.library, ShortcutScope.global},
        handlers: _shortcutHandlers,
        focusNode: _rootFocus,
        autofocus: true,
        child: Listener(
          onPointerDown: (e) {
            if (e.kind == PointerDeviceKind.mouse &&
                e.buttons == kBackMouseButton) {
              _unwind();
            }
          },
          child: Scaffold(
            backgroundColor: p.background,
            floatingActionButton: c.scope == NoteScope.active && !c.selecting
                ? FloatingActionButton(
                    tooltip: 'New note',
                    onPressed: _newNote,
                    child: const Icon(Icons.add_rounded, size: 26),
                  )
                : null,
            body: SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, cons) =>
                    _buildContent(context, cons.maxWidth),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _title {
    switch (_c.scope) {
      case NoteScope.archived:
        return 'Archive';
      case NoteScope.trash:
        return 'Trash';
      case NoteScope.conflicts:
        return 'Conflicts';
      case NoteScope.active:
        if (_c.unfiled) return 'Unfiled';
        return _c.currentFolder?.name ?? 'Notes';
    }
  }

  Widget _buildContent(BuildContext context, double width) {
    final c = _c;
    final s = _settings;
    final wide = width >= wideBreakpoint;
    final list = c.layout == LibraryLayout.list;
    final inset = contentInset(width, list: list);
    final subview = c.scope != NoteScope.active;
    return Column(
      children: [
        _buildHeader(context, wide, inset, subview),
        if (!subview && !c.searching)
          FolderStrip(
            folders: c.folders,
            counts: c.counts,
            selectedId: c.folderId,
            unfiledSelected: c.unfiled,
            inset: inset,
            onAll: _pickFolder,
            onFolder: (f) => _pickFolder(id: f.id),
            onUnfiled: () => _pickFolder(unfiled: true),
            onNew: _newFolder,
            onFolderMenu: _folderMenu,
          ),
        Expanded(child: _buildNotes(context, width, inset, s)),
      ],
    );
  }

  Widget _buildHeader(
    BuildContext context,
    bool wide,
    double inset,
    bool subview,
  ) {
    final p = AppPalette.of(context);
    final c = _c;
    final btn = hitSize(context);
    if (c.selecting) return _buildSelectionBar(inset);

    final menu = _OverflowMenu(
      controller: c,
      size: btn,
      onLayout: (v) => _settings.layout = v,
      onSort: (v) => _settings.sort = v,
      onGo: _go,
      onSettings: _openSettings,
      onEmptyTrash: _emptyTrash,
    );
    final side = inset - 8 < 0 ? 0.0 : inset - 8;
    final back = subview
        ? HeaderIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back to notes',
            onPressed: () => _go(NoteScope.active),
            size: btn,
          )
        : null;

    Widget row;
    if (!wide && _searchOpen) {
      row = Row(
        children: [
          HeaderIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Close search',
            onPressed: _closeSearch,
          ),
          Expanded(
            child: LibrarySearchField(
              controller: _searchCtl,
              focusNode: _searchFocus,
              onChanged: _onQueryChanged,
              onSubmitted: _rootFocus.requestFocus,
              autofocus: true,
            ),
          ),
          const SizedBox(width: 12),
        ],
      );
    } else {
      row = Row(
        children: [
          ?back,
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: back == null ? 8 : 4),
              child: Text(
                _title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // The title lives in a fixed 56 dp bar: past this scale it
                // would be clipped, and a heading needs no more than that.
                textScaler: MediaQuery.textScalerOf(context)
                    .clamp(maxScaleFactor: 1.5),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: p.text,
                ),
              ),
            ),
          ),
          if (wide) ...[
            SizedBox(
              width: 300,
              child: LibrarySearchField(
                controller: _searchCtl,
                focusNode: _searchFocus,
                onChanged: _onQueryChanged,
                onSubmitted: _rootFocus.requestFocus,
              ),
            ),
            const SizedBox(width: 4),
          ] else
            HeaderIconButton(
              icon: Icons.search_rounded,
              tooltip: 'Search',
              onPressed: _openSearch,
            ),
          menu,
        ],
      );
    }
    return SizedBox(
      height: 56,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: side),
        child: row,
      ),
    );
  }

  Widget _buildSelectionBar(double inset) {
    final c = _c;
    final sel = c.selectedNotes;
    final allPinned = sel.every((n) => n.pinned);
    final allArchived = sel.every((n) => n.archived);
    void act(String a) => _apply(a, c.selectedNotes);
    final actions = switch (c.scope) {
      NoteScope.trash => [
        SelectionAction(Icons.restore_rounded, 'Restore', () => act('restore')),
        SelectionAction(
          Icons.delete_forever_outlined,
          'Delete forever',
          () => act('purge'),
          danger: true,
        ),
      ],
      NoteScope.conflicts => [
        SelectionAction(
          Icons.call_split_rounded,
          'Keep as separate note',
          () => act('keep'),
        ),
        SelectionAction(
          Icons.delete_outline_rounded,
          'Move to Trash',
          () => act('trash'),
        ),
      ],
      _ => [
        SelectionAction(
          allPinned ? Icons.push_pin : Icons.push_pin_outlined,
          allPinned ? 'Unpin' : 'Pin',
          () => act('pin'),
        ),
        SelectionAction(
          allArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
          allArchived ? 'Unarchive' : 'Archive',
          () => act('archive'),
        ),
        SelectionAction(
          Icons.drive_file_move_outlined,
          'Move to folder',
          () => act('move'),
        ),
        SelectionAction(
          Icons.delete_outline_rounded,
          'Move to Trash',
          () => act('trash'),
        ),
      ],
    };
    return SelectionBar(
      count: sel.length,
      inset: inset,
      onClose: c.clearSelection,
      onSelectAll: c.selectAll,
      actions: actions,
    );
  }

  String get _emptyText {
    final c = _c;
    if (c.searching) return 'No notes match "${c.query.trim()}".';
    return switch (c.scope) {
      NoteScope.archived => 'Archive is empty.',
      NoteScope.trash => 'Trash is empty.',
      NoteScope.conflicts => 'No conflicts.',
      NoteScope.active =>
        c.unfiled
            ? 'No unfiled notes.'
            : c.folderId != null
            ? 'No notes in this folder.'
            : 'No notes yet. Tap + to write one.',
    };
  }

  Widget _buildNotes(
    BuildContext context,
    double width,
    double inset,
    AppSettings s,
  ) {
    final p = AppPalette.of(context);
    final c = _c;
    final items = c.items;
    final layout = c.layout;
    final now = DateTime.now();
    final byCreated = c.sort == NoteSort.created;
    final scaler = MediaQuery.textScalerOf(context);
    final cols = columnCount(width - 2 * inset);

    Widget itemFor(int i) {
      final item = items[i];
      final id = item.note.id;
      final sel = c.selected.contains(id);
      final child = layout == LibraryLayout.list
          ? NoteRow(
              item: item,
              showPreview: c.previewLines > 0,
              selected: sel,
              now: now,
              byCreated: byCreated,
              searching: c.searching,
              onTap: _onTap,
              onLongPress: _onLongPress,
              onMenu: _onMenu,
            )
          : NoteCard(
              item: item,
              previewLines: c.previewLines,
              selected: sel,
              now: now,
              byCreated: byCreated,
              searching: c.searching,
              fixedHeight: layout == LibraryLayout.grid,
              onTap: _onTap,
              onLongPress: _onLongPress,
              onMenu: _onMenu,
            );
      return KeyedSubtree(key: ValueKey(id), child: child);
    }

    SliverChildBuilderDelegate delegate(int start, int end) {
      return SliverChildBuilderDelegate(
        (context, i) => layout == LibraryLayout.list
            ? Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: itemFor(start + i),
              )
            : itemFor(start + i),
        childCount: end - start,
        findChildIndexCallback: (key) {
          final id = ((key as ValueKey).value) as String;
          final idx = c.indexOf(id);
          return idx >= start && idx < end ? idx - start : null;
        },
      );
    }

    Widget group(int start, int end, Key key) {
      switch (layout) {
        case LibraryLayout.grid:
          return SliverGrid(
            key: key,
            delegate: delegate(start, end),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: cardGap,
              crossAxisSpacing: cardGap,
              mainAxisExtent: gridCardExtent(
                previewLines: c.previewLines,
                scaler: scaler,
                tagRow: c.anyTagged,
              ),
            ),
          );
        case LibraryLayout.masonry:
          return SliverMasonryGrid(
            // SliverMasonryGrid keeps a column and offset for every child it
            // has laid out. When existing children are re-ordered those go
            // stale and cards end up in the wrong place for good. A key that
            // changes exactly when the order or membership changes gives a
            // fresh sliver then (see test/ui/library/masonry_reorder_test).
            key: ValueKey((
              key,
              Object.hashAll([
                for (var i = start; i < end; i++) items[i].note.id,
              ]),
            )),
            delegate: delegate(start, end),
            gridDelegate: SliverSimpleGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
            ),
            mainAxisSpacing: cardGap,
            crossAxisSpacing: cardGap,
          );
        case LibraryLayout.list:
          return SliverList(key: key, delegate: delegate(start, end));
      }
    }

    Widget label(String text, {required bool first}) => SliverToBoxAdapter(
      key: ValueKey('label-$text'),
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset + 2, first ? 2 : 14, inset, 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: p.textFaint,
          ),
        ),
      ),
    );

    Widget padded(Widget sliver) => SliverPadding(
      key: sliver.key,
      padding: EdgeInsets.symmetric(horizontal: inset),
      sliver: sliver,
    );

    final slivers = <Widget>[
      const SliverToBoxAdapter(child: SizedBox(height: 4)),
    ];
    if (items.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 96),
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                child: Text(
                  _emptyText,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, color: p.textMuted),
                ),
              ),
            ),
          ),
        ),
      );
    } else if (c.showGroups && layout != LibraryLayout.masonry) {
      slivers
        ..add(label('Pinned', first: true))
        ..add(padded(group(0, c.pinnedCount, const ValueKey('pinned'))))
        ..add(label('Others', first: false))
        ..add(
          padded(group(c.pinnedCount, items.length, const ValueKey('others'))),
        );
    } else {
      slivers.add(padded(group(0, items.length, const ValueKey('others'))));
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 96)));

    return Scrollbar(
      controller: _scroll,
      child: CustomScrollView(controller: _scroll, slivers: slivers),
    );
  }
}

/// The single overflow menu: layout, sort, sub-views, settings.
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.controller,
    required this.size,
    required this.onLayout,
    required this.onSort,
    required this.onGo,
    required this.onSettings,
    required this.onEmptyTrash,
  });

  final LibraryController controller;
  final double size;
  final ValueChanged<LibraryLayout> onLayout;
  final ValueChanged<NoteSort> onSort;
  final ValueChanged<NoteScope> onGo;
  final VoidCallback onSettings;
  final VoidCallback onEmptyTrash;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final counts = c.counts;
    String? n(int v) => v > 0 ? '$v' : null;
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert_rounded, size: 21),
      padding: EdgeInsets.zero,
      iconSize: 21,
      style: IconButton.styleFrom(
        minimumSize: Size(size, size),
        fixedSize: Size(size, size),
        padding: EdgeInsets.zero,
      ),
      popUpAnimationStyle: animationStyleOf(context),
      onSelected: (v) {
        final parts = v.split(':');
        switch (parts[0]) {
          case 'layout':
            onLayout(LibraryLayout.values.byName(parts[1]));
          case 'sort':
            onSort(NoteSort.values.byName(parts[1]));
          case 'go':
            onGo(NoteScope.values.byName(parts[1]));
          case 'settings':
            onSettings();
          case 'empty':
            onEmptyTrash();
        }
      },
      itemBuilder: (context) => [
        menuLabel(context, 'Layout'),
        for (final (v, label) in [
          (LibraryLayout.grid, 'Grid'),
          (LibraryLayout.masonry, 'Masonry'),
          (LibraryLayout.list, 'List'),
        ])
          menuItem(
            context,
            'layout:${v.name}',
            label,
            checked: c.layout == v,
            reserveIcon: true,
          ),
        const PopupMenuDivider(height: 8),
        menuLabel(context, 'Sort by'),
        for (final (v, label) in [
          (NoteSort.modified, 'Modified'),
          (NoteSort.created, 'Created'),
          (NoteSort.title, 'Title'),
        ])
          menuItem(
            context,
            'sort:${v.name}',
            label,
            checked: c.sort == v,
            reserveIcon: true,
          ),
        const PopupMenuDivider(height: 8),
        if (c.scope != NoteScope.active)
          menuItem(
            context,
            'go:active',
            'All notes',
            icon: Icons.notes_rounded,
          ),
        if (c.scope != NoteScope.archived)
          menuItem(
            context,
            'go:archived',
            'Archive',
            icon: Icons.archive_outlined,
            trailing: n(counts.archived),
          ),
        if (c.scope != NoteScope.trash)
          menuItem(
            context,
            'go:trash',
            'Trash',
            icon: Icons.delete_outline_rounded,
            trailing: n(counts.trash),
          ),
        if (counts.conflicts > 0 && c.scope != NoteScope.conflicts)
          menuItem(
            context,
            'go:conflicts',
            'Conflicts',
            icon: Icons.call_split_rounded,
            trailing: n(counts.conflicts),
          ),
        if (c.scope == NoteScope.trash && counts.trash > 0)
          menuItem(
            context,
            'empty',
            'Empty Trash',
            icon: Icons.delete_forever_outlined,
            danger: true,
          ),
        const PopupMenuDivider(height: 8),
        menuItem(
          context,
          'settings',
          'Settings',
          icon: Icons.settings_outlined,
        ),
      ],
    );
  }
}
