import 'package:flutter/widgets.dart';

// Intents for every keyboard shortcut in the app. Definitions live in
// shortcut_defs.dart; screens supply the handlers.

/// Ctrl+N: create a note (library).
class NewNoteIntent extends Intent {
  const NewNoteIntent();
}

/// Ctrl+F and `/`: focus the library search field.
class FocusSearchIntent extends Intent {
  const FocusSearchIntent();
}

/// `/`: focus the library search field, but only when no text is focused.
class SlashSearchIntent extends Intent {
  const SlashSearchIntent();
}

/// Ctrl+A: select every visible note (library).
class SelectAllNotesIntent extends Intent {
  const SelectAllNotesIntent();
}

/// Delete: trash, or purge in the trash view, the selected notes (library).
class TrashSelectedIntent extends Intent {
  const TrashSelectedIntent();
}

/// Alt+Left: return to the All notes view (library).
class BackToAllNotesIntent extends Intent {
  const BackToAllNotesIntent();
}

/// Ctrl+Comma: open Settings (global).
class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}

/// F1: open Help (global).
class OpenHelpIntent extends Intent {
  const OpenHelpIntent();
}

/// Ctrl+S: save the open note now, flushing pending edits (editor).
class SaveNowIntent extends Intent {
  const SaveNowIntent();
}

/// Ctrl+K: quick navigation. Definition only; no UI exists yet.
class QuickNavIntent extends Intent {
  const QuickNavIntent();
}

/// Escape: layered. Resolved by [resolveEscape]; named EscapeIntent so it
/// does not clash with Flutter's DismissIntent.
class EscapeIntent extends Intent {
  const EscapeIntent();
}
