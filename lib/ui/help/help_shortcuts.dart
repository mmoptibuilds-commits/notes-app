import '../shortcuts/shortcut_defs.dart';
import 'help_shortcut.dart';

/// Shortcuts listed in Help, generated from the same definitions the screens
/// bind, so the list cannot drift from the real keys.
List<HelpShortcut> helpShortcuts() => [
  for (final e in helpEntries())
    HelpShortcut(keys: e.label, description: e.description),
];
