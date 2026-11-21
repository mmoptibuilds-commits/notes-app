import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_settings.dart';
import '../../data/models.dart';
import '../../data/note_repository.dart';

/// One row of the library: a note and, for search results, its snippet.
class LibraryItem {
  const LibraryItem(this.note, [this.snippet = '']);
  final NoteSummary note;
  final String snippet;
}

/// Settings key remembering the selected folder. Value is a folder id,
/// [unfiledKey], or absent for "All".
const folderSettingKey = 'library.folder';
const unfiledKey = 'unfiled';

/// What the library is showing and what is selected. Loads the list once per
/// change (not per build) and never reads note bodies.
class LibraryController extends ChangeNotifier {
  LibraryController(this.notes, this.settings) {
    switch (settings.startupView) {
      case StartupView.unfiled:
        _unfiled = true;
        break;
      case StartupView.all:
        break;
      case StartupView.last:
        final saved = settings.read(folderSettingKey);
        if (saved == unfiledKey) {
          _unfiled = true;
        } else if (saved != null && saved.isNotEmpty) {
          _folderId = saved;
        }
    }
    _layout = settings.layout;
    _sort = settings.sort;
    _previewLines = settings.previewLines;
    notes.changes.addListener(_onRepoChanged);
    settings.addListener(_onSettingsChanged);
    reload();
  }

  final NoteRepository notes;
  final AppSettings settings;

  NoteScope _scope = NoteScope.active;
  String? _folderId;
  bool _unfiled = false;
  String _query = '';
  late LibraryLayout _layout;
  late NoteSort _sort;
  late int _previewLines;

  List<LibraryItem> _items = const [];
  Map<String, int> _indexById = const {};
  int _pinnedCount = 0;
  List<Folder> _folders = const [];
  LibraryCounts _counts = const LibraryCounts(
    active: 0,
    unfiled: 0,
    archived: 0,
    trash: 0,
    conflicts: 0,
  );
  final Set<String> _selected = {};

  bool _covered = false;
  bool _dirty = false;
  bool _scheduled = false;
  bool _disposed = false;

  bool get covered => _covered;
  NoteScope get scope => _scope;
  String? get folderId => _scope == NoteScope.active ? _folderId : null;
  bool get unfiled => _scope == NoteScope.active && _unfiled;
  String get query => _query;
  bool get searching => _query.trim().isNotEmpty;
  LibraryLayout get layout => _layout;
  NoteSort get sort => _sort;
  int get previewLines => _previewLines;

  List<LibraryItem> get items => _items;
  int indexOf(String id) => _indexById[id] ?? -1;

  /// Number of leading pinned items; only meaningful when [showGroups].
  int get pinnedCount => _pinnedCount;

  /// Pinned/Others labels appear only when both groups are non-empty.
  bool get showGroups =>
      _scope == NoteScope.active &&
      !searching &&
      _pinnedCount > 0 &&
      _pinnedCount < _items.length;

  List<Folder> get folders => _folders;
  LibraryCounts get counts => _counts;
  Set<String> get selected => _selected;
  bool get selecting => _selected.isNotEmpty;

  Folder? get currentFolder {
    final id = folderId;
    if (id == null) return null;
    for (final f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Scroll bucket: each view keeps its own offset.
  String get viewKey {
    if (searching) return 'search';
    return '${_scope.name}|${folderId ?? (unfiled ? unfiledKey : '')}';
  }

  /// True when any shown note needs a tag row (conflict copy, archived hit).
  bool get anyTagged => _items.any(
    (i) => i.note.isConflictCopy || (searching && i.note.archived),
  );

  // ----------------------------------------------------------------- view

  void setScope(NoteScope scope) {
    if (_scope == scope && !searching) return;
    _scope = scope;
    _query = '';
    _selected.clear();
    reload();
  }

  void selectFolder({String? id, bool unfiled = false}) {
    _scope = NoteScope.active;
    _folderId = id;
    _unfiled = unfiled;
    _query = '';
    _selected.clear();
    settings.write(folderSettingKey, unfiled ? unfiledKey : id);
    reload();
  }

  void setQuery(String q) {
    if (q == _query) return;
    _query = q;
    reload();
  }

  /// While a route covers the library, changes are only noted; the reload
  /// happens when it is visible again.
  void setCovered(bool covered) {
    if (_covered == covered) return;
    _covered = covered;
    if (!covered && _dirty) _scheduleReload();
  }

  void _onRepoChanged() {
    if (_covered) {
      _dirty = true;
      return;
    }
    _scheduleReload();
  }

  void _scheduleReload() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_disposed && !_covered) reload();
    });
  }

  void _onSettingsChanged() {
    final sortChanged = settings.sort != _sort;
    final changed =
        sortChanged ||
        settings.layout != _layout ||
        settings.previewLines != _previewLines;
    _sort = settings.sort;
    _layout = settings.layout;
    _previewLines = settings.previewLines;
    if (sortChanged) {
      reload();
    } else if (changed) {
      notifyListeners();
    }
  }

  /// Re-reads folders, counts and the list. Called once per change.
  void reload() {
    _dirty = false;
    _folders = notes.listFolders();
    _counts = notes.counts();
    if (_folderId != null && _folders.every((f) => f.id != _folderId)) {
      _folderId = null;
      settings.write(folderSettingKey, null);
    }
    if (_unfiled && _folders.isEmpty) {
      _unfiled = false;
      settings.write(folderSettingKey, null);
    }
    if (searching) {
      _items = [
        for (final h in notes.search(_query, scope: _scope))
          LibraryItem(h.note, h.snippet),
      ];
    } else {
      final filter = _scope != NoteScope.active
          ? const FolderFilter.all()
          : _unfiled
          ? const FolderFilter.unfiled()
          : _folderId != null
          ? FolderFilter.folder(_folderId!)
          : const FolderFilter.all();
      _items = [
        for (final n in notes.listNotes(
          scope: _scope,
          folder: filter,
          sort: _sort,
        ))
          LibraryItem(n),
      ];
    }
    _indexById = {for (var i = 0; i < _items.length; i++) _items[i].note.id: i};
    var pinned = 0;
    while (pinned < _items.length && _items[pinned].note.pinned) {
      pinned++;
    }
    _pinnedCount = pinned;
    final live = _indexById.keys.toSet();
    _selected.removeWhere((id) => !live.contains(id));
    notifyListeners();
  }

  // ------------------------------------------------------------ selection

  void toggle(String id) {
    if (!_selected.add(id)) _selected.remove(id);
    notifyListeners();
  }

  void selectOnly(String id) {
    _selected
      ..clear()
      ..add(id);
    notifyListeners();
  }

  void selectAll() {
    _selected
      ..clear()
      ..addAll(_items.map((i) => i.note.id));
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  List<NoteSummary> get selectedNotes => [
    for (final i in _items)
      if (_selected.contains(i.note.id)) i.note,
  ];

  @override
  void dispose() {
    _disposed = true;
    notes.changes.removeListener(_onRepoChanged);
    settings.removeListener(_onSettingsChanged);
    super.dispose();
  }
}
