import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'shortcut_intents.dart';

/// Where a shortcut is bound. Screens bind their own scope plus [global].
enum ShortcutScope { global, library, editor }

/// Stable identifiers, one per shortcut.
enum ShortcutId {
  newNote,
  focusSearch,
  slashSearch,
  selectAll,
  trashSelected,
  backToAllNotes,
  openSettings,
  openHelp,
  escape,
  quickNav,
  saveNow,
}

/// One keyboard shortcut. Its label for Help is derived from [activators], so
/// the Help text cannot drift from the bindings.
class ShortcutDef {
  const ShortcutDef({
    required this.id,
    required this.scope,
    required this.activators,
    required this.intent,
    required this.description,
    this.requiresNoTextFocus = false,
    this.implemented = true,
  });

  final ShortcutId id;
  final ShortcutScope scope;

  /// Every key combination that triggers this shortcut (for example Ctrl and
  /// Meta variants). The first one names the shortcut in Help.
  final List<ShortcutActivator> activators;
  final Intent intent;
  final String description;

  /// When true the shortcut is inert while an EditableText or the Quill editor
  /// has focus. Bare keys (`/`, Delete) and Ctrl+A must set this so they never
  /// steal typing.
  final bool requiresNoTextFocus;

  /// False for definitions without a UI yet. Such definitions are never bound
  /// and never listed in Help.
  final bool implemented;

  String get label => activatorLabel(activators.first);

  /// Identity of each activator, used to check that bindings do not collide.
  Iterable<String> get signatures => activators.map(activatorSignature);
}

/// One row of the Help screen.
class ShortcutHelpEntry {
  const ShortcutHelpEntry({
    required this.label,
    required this.description,
    required this.scope,
  });

  final String label;
  final String description;
  final ShortcutScope scope;
}

const _newNoteActivators = [
  SingleActivator(
    LogicalKeyboardKey.keyN,
    control: true,
    includeRepeats: false,
  ),
  SingleActivator(LogicalKeyboardKey.keyN, meta: true, includeRepeats: false),
];

/// Every shortcut in the app. This list is the single source of truth.
final List<ShortcutDef> kShortcutDefs = [
  ShortcutDef(
    id: ShortcutId.newNote,
    scope: ShortcutScope.library,
    activators: _newNoteActivators,
    intent: const NewNoteIntent(),
    description: 'New note',
  ),
  ShortcutDef(
    id: ShortcutId.focusSearch,
    scope: ShortcutScope.library,
    activators: [
      SingleActivator(
        LogicalKeyboardKey.keyF,
        control: true,
        includeRepeats: false,
      ),
      SingleActivator(
        LogicalKeyboardKey.keyF,
        meta: true,
        includeRepeats: false,
      ),
    ],
    intent: const FocusSearchIntent(),
    description: 'Focus search',
  ),
  ShortcutDef(
    id: ShortcutId.slashSearch,
    scope: ShortcutScope.library,
    // CharacterActivator, not SingleActivator(slash): '/' needs Shift on some
    // keyboard layouts. Kept separate from Ctrl+F because it is a bare key.
    activators: [CharacterActivator('/', includeRepeats: false)],
    intent: const SlashSearchIntent(),
    description: 'Focus search (when not typing)',
    requiresNoTextFocus: true,
  ),
  ShortcutDef(
    id: ShortcutId.selectAll,
    scope: ShortcutScope.library,
    activators: [
      SingleActivator(
        LogicalKeyboardKey.keyA,
        control: true,
        includeRepeats: false,
      ),
      SingleActivator(
        LogicalKeyboardKey.keyA,
        meta: true,
        includeRepeats: false,
      ),
    ],
    intent: const SelectAllNotesIntent(),
    description: 'Select all notes',
    requiresNoTextFocus: true,
  ),
  ShortcutDef(
    id: ShortcutId.trashSelected,
    scope: ShortcutScope.library,
    activators: [
      SingleActivator(LogicalKeyboardKey.delete, includeRepeats: false),
    ],
    intent: const TrashSelectedIntent(),
    description: 'Move selected notes to trash (purge in trash)',
    requiresNoTextFocus: true,
  ),
  ShortcutDef(
    id: ShortcutId.backToAllNotes,
    scope: ShortcutScope.library,
    activators: [
      SingleActivator(
        LogicalKeyboardKey.arrowLeft,
        alt: true,
        includeRepeats: false,
      ),
    ],
    intent: const BackToAllNotesIntent(),
    description: 'Back to All notes',
    requiresNoTextFocus: true,
  ),
  ShortcutDef(
    id: ShortcutId.openSettings,
    scope: ShortcutScope.global,
    activators: [
      SingleActivator(
        LogicalKeyboardKey.comma,
        control: true,
        includeRepeats: false,
      ),
      SingleActivator(
        LogicalKeyboardKey.comma,
        meta: true,
        includeRepeats: false,
      ),
    ],
    intent: const OpenSettingsIntent(),
    description: 'Open Settings',
  ),
  ShortcutDef(
    id: ShortcutId.openHelp,
    scope: ShortcutScope.global,
    activators: [SingleActivator(LogicalKeyboardKey.f1, includeRepeats: false)],
    intent: const OpenHelpIntent(),
    description: 'Open Help',
  ),
  ShortcutDef(
    id: ShortcutId.escape,
    scope: ShortcutScope.global,
    activators: [
      SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false),
    ],
    intent: const EscapeIntent(),
    description: 'Close the popup or dialog, then clear search or selection, then go back',
  ),
  ShortcutDef(
    id: ShortcutId.quickNav,
    scope: ShortcutScope.global,
    activators: [
      SingleActivator(
        LogicalKeyboardKey.keyK,
        control: true,
        includeRepeats: false,
      ),
      SingleActivator(
        LogicalKeyboardKey.keyK,
        meta: true,
        includeRepeats: false,
      ),
    ],
    intent: const QuickNavIntent(),
    description: 'Quick navigation (not implemented yet)',
    // Quill binds Ctrl+K to apply a link while the editor has focus, so this
    // stays unbound until a UI exists.
    implemented: false,
  ),
  ShortcutDef(
    id: ShortcutId.saveNow,
    scope: ShortcutScope.editor,
    activators: [
      SingleActivator(
        LogicalKeyboardKey.keyS,
        control: true,
        includeRepeats: false,
      ),
      SingleActivator(
        LogicalKeyboardKey.keyS,
        meta: true,
        includeRepeats: false,
      ),
    ],
    intent: const SaveNowIntent(),
    description: 'Save now',
  ),
];

/// Human label such as "Ctrl+N" or "Alt+Left".
String activatorLabel(ShortcutActivator a) {
  if (a is CharacterActivator) {
    return _modifiers(
          alt: a.alt,
          control: a.control,
          meta: a.meta,
          shift: false,
        ) +
        a.character;
  }
  final s = a as SingleActivator;
  return _modifiers(
        alt: s.alt,
        control: s.control,
        meta: s.meta,
        shift: s.shift,
      ) +
      _keyName(s.trigger);
}

String _modifiers({
  required bool alt,
  required bool control,
  required bool meta,
  required bool shift,
}) {
  final b = StringBuffer();
  if (control) b.write('Ctrl+');
  if (meta) b.write('Meta+');
  if (alt) b.write('Alt+');
  if (shift) b.write('Shift+');
  return b.toString();
}

String _keyName(LogicalKeyboardKey k) {
  if (k == LogicalKeyboardKey.comma) return 'Comma';
  if (k == LogicalKeyboardKey.arrowLeft) return 'Left';
  if (k == LogicalKeyboardKey.delete) return 'Delete';
  if (k == LogicalKeyboardKey.escape) return 'Esc';
  if (k == LogicalKeyboardKey.f1) return 'F1';
  final l = k.keyLabel;
  return l.length == 1 ? l.toUpperCase() : l;
}

/// Stable identity for an activator: trigger or character plus modifiers.
String activatorSignature(ShortcutActivator a) {
  if (a is CharacterActivator) {
    return 'char:${a.character}|c=${a.control}|a=${a.alt}|m=${a.meta}';
  }
  final s = a as SingleActivator;
  return 'key:${s.trigger.keyId}|c=${s.control}|s=${s.shift}|a=${s.alt}|m=${s.meta}';
}

/// Help rows for the implemented shortcuts in [scopes], in definition order.
List<ShortcutHelpEntry> helpEntries({
  Iterable<ShortcutScope> scopes = ShortcutScope.values,
}) {
  final wanted = scopes.toSet();
  return [
    for (final d in kShortcutDefs)
      if (d.implemented && wanted.contains(d.scope))
        ShortcutHelpEntry(
          label: d.label,
          description: d.description,
          scope: d.scope,
        ),
  ];
}
