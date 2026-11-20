import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'shortcut_defs.dart';

// Focus guards, Escape layering and the Shortcuts/Actions wiring.
// Pure functions are used wherever possible so the rules are unit-tested.

/// What the shortcut system needs to know about the current focus.
class ShortcutFocus {
  const ShortcutFocus({
    required this.routeAccepts,
    required this.editableTextFocused,
    required this.quillFocused,
  });

  /// False while a dialog, sheet or popup is above the screen, or the screen
  /// is not the current route.
  final bool routeAccepts;

  /// True when the primary focus is inside an EditableText (TextField).
  final bool editableTextFocused;

  /// True when the primary focus is inside the Quill editor. Quill uses its own
  /// text-input client, not EditableText, so it needs its own check.
  final bool quillFocused;

  bool get textFocused => editableTextFocused || quillFocused;
}

/// A bare key (no Ctrl/Alt/Meta) may act only when no route is above and no
/// text input has focus.
bool shouldHandleBareKey(ShortcutFocus f) => f.routeAccepts && !f.textFocused;

/// Whether [def] may run now. Modifier shortcuts only check the route, so
/// Ctrl+N still works while a field is focused, as before. Shortcuts that set
/// [ShortcutDef.requiresNoTextFocus] also check the text focus.
bool shouldHandleShortcut(ShortcutDef def, ShortcutFocus f) {
  if (!f.routeAccepts) return false;
  if (def.requiresNoTextFocus) return !f.textFocused;
  return true;
}

/// Outcomes of pressing Escape, in priority order.
enum EscapeOutcome {
  closePopup,
  clearSearch,
  clearSelection,
  unfocusSearch,
  back,
  unhandled,
}

/// Escape layering, outermost first: popup, then search, then selection, then
/// leaving search focus, then back. Dialogs close via their own route, so
/// [popupOpen] is only for surfaces the app opens itself.
EscapeOutcome resolveEscape({
  required bool popupOpen,
  required bool hasSearch,
  required bool selecting,
  required bool searchFocused,
  required bool canGoBack,
}) {
  if (popupOpen) return EscapeOutcome.closePopup;
  if (hasSearch) return EscapeOutcome.clearSearch;
  if (selecting) return EscapeOutcome.clearSelection;
  if (searchFocused) return EscapeOutcome.unfocusSearch;
  if (canGoBack) return EscapeOutcome.back;
  return EscapeOutcome.unhandled;
}

bool _routeAccepts(BuildContext? ctx) {
  if (ctx == null) return true;
  final route = ModalRoute.of(ctx);
  if (route == null) return true;
  // Dialogs, sheets and menus are PopupRoutes. Any of them makes the
  // shortcut inert, even when the screen's route still reports current.
  return route.isCurrent && route is! PopupRoute;
}

/// Reads the current focus. [scopeContext] is the context of the screen or
/// shell that binds the shortcut. The primary-focus route is checked too, so
/// a dialog that takes focus also blocks shortcuts bound higher up.
ShortcutFocus currentShortcutFocus(BuildContext scopeContext) {
  final primary = FocusManager.instance.primaryFocus?.context;
  return ShortcutFocus(
    routeAccepts: _routeAccepts(scopeContext) && _routeAccepts(primary),
    editableTextFocused:
        primary?.findAncestorWidgetOfExactType<EditableText>() != null,
    quillFocused:
        primary?.findAncestorStateOfType<QuillRawEditorState>() != null,
  );
}

/// An Action that runs [onInvoke] only when [shouldHandleShortcut] allows it.
/// The guard is in isEnabled, so a disabled action lets the key bubble up as
/// unhandled and a typed character is never swallowed.
class ScopedAction extends Action<Intent> {
  ScopedAction({
    required this.def,
    required this.scopeContext,
    required this.onInvoke,
  });

  final ShortcutDef def;
  final BuildContext scopeContext;
  final VoidCallback onInvoke;

  @override
  bool isEnabled(Intent intent) =>
      shouldHandleShortcut(def, currentShortcutFocus(scopeContext));

  @override
  Object? invoke(Intent intent) {
    onInvoke();
    return null;
  }
}

/// Binds every implemented definition in [scopes] that has a handler in
/// [handlers]. Screens pass their own scope plus [ShortcutScope.global].
Widget shortcutScope({
  required Set<ShortcutScope> scopes,
  required Map<ShortcutId, VoidCallback> handlers,
  required Widget child,
}) {
  return Builder(
    builder: (context) {
      final shortcuts = <ShortcutActivator, Intent>{};
      final actions = <Type, Action<Intent>>{};
      for (final def in kShortcutDefs) {
        final handler = handlers[def.id];
        if (!def.implemented || handler == null) continue;
        if (!scopes.contains(def.scope)) continue;
        for (final a in def.activators) {
          shortcuts[a] = def.intent;
        }
        actions[def.intent.runtimeType] = ScopedAction(
          def: def,
          scopeContext: context,
          onInvoke: handler,
        );
      }
      return Shortcuts(
        shortcuts: shortcuts,
        child: Actions(actions: actions, child: child),
      );
    },
  );
}
