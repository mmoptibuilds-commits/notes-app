import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_database.dart';
import 'note_repository.dart' show NoteSort;

enum AppTheme { amoled, charcoal, light }

enum LibraryLayout { grid, masonry, list }

enum AnimationLevel { off, reduced, full }

/// Font choices. [system] uses the platform default; the rest are bundled.
enum AppFont {
  system('System', null),
  inter('Inter', 'Inter'),
  serif('Source Serif', 'SourceSerif4'),
  mono('JetBrains Mono', 'JetBrainsMono'),
  hyperlegible('Atkinson Hyperlegible', 'AtkinsonHyperlegible');

  const AppFont(this.label, this.family);
  final String label;

  /// Flutter font family name, or null for the platform default.
  final String? family;
}

/// Buttons the editor toolbar can show. The user picks which and in what order.
enum ToolbarItem {
  bold,
  italic,
  underline,
  strike,
  heading1,
  heading2,
  heading3,
  bulletList,
  numberedList,
  checklist,
  quote,
  codeBlock,
  inlineCode,
  link,
  image,
  indent,
  outdent,
  clearFormat,
  undo,
  redo;

  static const defaults = [
    checklist,
    bold,
    italic,
    heading1,
    heading2,
    bulletList,
    numberedList,
    quote,
    codeBlock,
    link,
    image,
    undo,
    redo,
  ];
}

/// Per-device preferences, persisted in the `settings` table. Not synced.
///
/// Setters persist immediately and notify listeners.
class AppSettings extends ChangeNotifier {
  AppSettings(this._db) {
    for (final r in _db.select('SELECT key, value FROM settings')) {
      _values[r['key'] as String] = r['value'] as String;
    }
  }

  final AppDatabase _db;
  final _values = <String, String>{};

  AppTheme get theme => _enum('theme', AppTheme.values, AppTheme.amoled);
  set theme(AppTheme v) => _set('theme', v.name);

  /// Font for the interface.
  AppFont get uiFont => _enum('uiFont', AppFont.values, AppFont.inter);
  set uiFont(AppFont v) => _set('uiFont', v.name);

  /// Font for note text.
  AppFont get editorFont => _enum('editorFont', AppFont.values, AppFont.inter);
  set editorFont(AppFont v) => _set('editorFont', v.name);

  /// Multiplier for interface text, 0.85 to 1.4.
  double get textScale => _double('textScale', 1.0, 0.85, 1.4);
  set textScale(double v) => _set('textScale', '${v.clamp(0.85, 1.4)}');

  /// Note body size in logical pixels, 12 to 28.
  double get editorFontSize => _double('editorFontSize', 16, 12, 28);
  set editorFontSize(double v) => _set('editorFontSize', '${v.clamp(12, 28)}');

  /// Note body line height multiplier, 1.1 to 2.0.
  double get editorLineHeight => _double('editorLineHeight', 1.45, 1.1, 2.0);
  set editorLineHeight(double v) =>
      _set('editorLineHeight', '${v.clamp(1.1, 2.0)}');

  LibraryLayout get layout =>
      _enum('layout', LibraryLayout.values, LibraryLayout.masonry);
  set layout(LibraryLayout v) => _set('layout', v.name);

  NoteSort get sort => _enum('sort', NoteSort.values, NoteSort.modified);
  set sort(NoteSort v) => _set('sort', v.name);

  /// Body lines shown on a card, 0 to 10.
  int get previewLines => _double('previewLines', 6, 0, 10).round();
  set previewLines(int v) => _set('previewLines', '${v.clamp(0, 10)}');

  AnimationLevel get animations =>
      _enum('animations', AnimationLevel.values, AnimationLevel.full);
  set animations(AnimationLevel v) => _set('animations', v.name);

  /// Whether checked checklist items move to the collapsible completed section.
  bool get completedSection => _values['completedSection'] != 'false';
  set completedSection(bool v) => _set('completedSection', '$v');

  /// Whether the completed section starts collapsed.
  bool get completedCollapsed => _values['completedCollapsed'] != 'false';
  set completedCollapsed(bool v) => _set('completedCollapsed', '$v');

  List<ToolbarItem> get toolbar {
    final raw = _values['toolbar'];
    if (raw == null) return ToolbarItem.defaults;
    try {
      final names = (jsonDecode(raw) as List).cast<String>();
      final byName = {for (final t in ToolbarItem.values) t.name: t};
      return [
        for (final n in names)
          if (byName[n] != null) byName[n]!,
      ];
    } on Object {
      return ToolbarItem.defaults;
    }
  }

  set toolbar(List<ToolbarItem> v) =>
      _set('toolbar', jsonEncode([for (final t in v) t.name]));

  /// Raw access for small bits of UI state (for example, last opened folder).
  String? read(String key) => _values[key];
  void write(String key, String? value) {
    if (value == null) {
      if (_values.remove(key) == null) return;
      _db.execute('DELETE FROM settings WHERE key = ?', [key]);
      notifyListeners();
    } else {
      _set(key, value);
    }
  }

  void _set(String key, String value) {
    if (_values[key] == value) return;
    _values[key] = value;
    _db.execute(
      'INSERT INTO settings(key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
    notifyListeners();
  }

  T _enum<T extends Enum>(String key, List<T> values, T fallback) {
    final raw = _values[key];
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return fallback;
  }

  double _double(String key, double fallback, double min, double max) {
    final v = double.tryParse(_values[key] ?? '');
    return v == null ? fallback : v.clamp(min, max).toDouble();
  }
}
