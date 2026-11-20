import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ui/shortcuts/shortcut_defs.dart';
import 'package:notes/ui/shortcuts/shortcut_guards.dart';

void main() {
  group('definitions', () {
    test('every activator is unique within its scope and within global', () {
      for (final scope in ShortcutScope.values) {
        final seen = <String, ShortcutId>{};
        for (final d in kShortcutDefs) {
          if (!d.implemented) continue;
          if (d.scope != scope && d.scope != ShortcutScope.global) continue;
          for (final sig in d.signatures) {
            expect(
              seen.containsKey(sig),
              isFalse,
              reason: '${d.id} collides with ${seen[sig]} in $scope ($sig)',
            );
            seen[sig] = d.id;
          }
        }
      }
    });

    test('labels are derived from the activators and match the spec', () {
      final labels = {for (final d in kShortcutDefs) d.id: d.label};
      expect(labels[ShortcutId.newNote], 'Ctrl+N');
      expect(labels[ShortcutId.focusSearch], 'Ctrl+F');
      expect(labels[ShortcutId.selectAll], 'Ctrl+A');
      expect(labels[ShortcutId.trashSelected], 'Delete');
      expect(labels[ShortcutId.backToAllNotes], 'Alt+Left');
      expect(labels[ShortcutId.openSettings], 'Ctrl+Comma');
      expect(labels[ShortcutId.openHelp], 'F1');
      expect(labels[ShortcutId.escape], 'Esc');
      expect(labels[ShortcutId.saveNow], 'Ctrl+S');
    });

    test('every id is defined exactly once', () {
      final ids = kShortcutDefs.map((d) => d.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.toSet(), ShortcutId.values.toSet());
    });

    test('the slash key is a text-guarded character shortcut', () {
      final slash = kShortcutDefs.firstWhere(
        (d) => d.id == ShortcutId.slashSearch,
      );
      expect(slash.label, '/');
      expect(slash.requiresNoTextFocus, isTrue);
      expect(
        slash.activators.whereType<CharacterActivator>().single.character,
        '/',
      );
      final ctrlF = kShortcutDefs.firstWhere(
        (d) => d.id == ShortcutId.focusSearch,
      );
      expect(ctrlF.requiresNoTextFocus, isFalse);
    });

    test('Ctrl+K is defined but never bound or listed (no UI yet)', () {
      final qk = kShortcutDefs.firstWhere((d) => d.id == ShortcutId.quickNav);
      expect(qk.implemented, isFalse);
      expect(helpEntries().map((e) => e.label), isNot(contains('Ctrl+K')));
    });

    test('the editor scope adds only Ctrl+S and avoids Quill keys', () {
      // Quill's default table binds these letters while the editor has focus.
      final quillReserved = {
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyI,
        LogicalKeyboardKey.keyU,
        LogicalKeyboardKey.keyK,
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.keyG,
        LogicalKeyboardKey.keyM,
        LogicalKeyboardKey.keyZ,
        LogicalKeyboardKey.keyY,
      };
      final editor = kShortcutDefs.where(
        (d) => d.scope == ShortcutScope.editor,
      );
      expect(editor.map((d) => d.id), [ShortcutId.saveNow]);
      for (final d in editor) {
        for (final a in d.activators) {
          final s = a as SingleActivator;
          expect(quillReserved.contains(s.trigger), isFalse);
          expect(s.shift, isFalse, reason: 'Ctrl+Shift+S is Quill strike');
        }
      }
    });

    test('Ctrl+F and Ctrl+K are not bound in the editor scope', () {
      final editorSigs = kShortcutDefs
          .where((d) => d.scope == ShortcutScope.editor)
          .expand((d) => d.signatures)
          .toSet();
      final ctrlF = SingleActivator(LogicalKeyboardKey.keyF, control: true);
      final ctrlK = SingleActivator(LogicalKeyboardKey.keyK, control: true);
      expect(editorSigs, isNot(contains(activatorSignature(ctrlF))));
      expect(editorSigs, isNot(contains(activatorSignature(ctrlK))));
    });
  });

  group('help entries', () {
    test('are derived from definitions: one per implemented shortcut', () {
      final entries = helpEntries();
      final implemented = kShortcutDefs.where((d) => d.implemented).toList();
      expect(entries.length, implemented.length);
      for (var i = 0; i < implemented.length; i++) {
        expect(entries[i].label, implemented[i].label);
        expect(entries[i].description, implemented[i].description);
        expect(entries[i].scope, implemented[i].scope);
      }
    });

    test('filter by scope', () {
      final lib = helpEntries(scopes: {ShortcutScope.library});
      expect(lib.every((e) => e.scope == ShortcutScope.library), isTrue);
      expect(lib.map((e) => e.label), contains('Alt+Left'));
    });
  });

  group('escape layering', () {
    EscapeOutcome esc({
      bool popup = false,
      bool search = false,
      bool selecting = false,
      bool searchFocused = false,
      bool back = false,
    }) => resolveEscape(
      popupOpen: popup,
      hasSearch: search,
      selecting: selecting,
      searchFocused: searchFocused,
      canGoBack: back,
    );

    test('closes the outermost layer first', () {
      expect(
        esc(popup: true, search: true, selecting: true, back: true),
        EscapeOutcome.closePopup,
      );
      expect(
        esc(search: true, selecting: true, searchFocused: true, back: true),
        EscapeOutcome.clearSearch,
      );
      expect(
        esc(selecting: true, searchFocused: true, back: true),
        EscapeOutcome.clearSelection,
      );
      expect(esc(searchFocused: true, back: true), EscapeOutcome.unfocusSearch);
      expect(esc(back: true), EscapeOutcome.back);
      expect(esc(), EscapeOutcome.unhandled);
    });
  });

  group('guards (pure)', () {
    ShortcutFocus f({
      bool route = true,
      bool editable = false,
      bool quill = false,
    }) => ShortcutFocus(
      routeAccepts: route,
      editableTextFocused: editable,
      quillFocused: quill,
    );

    test('a bare key runs only with no route above and no text focus', () {
      expect(shouldHandleBareKey(f()), isTrue);
      expect(shouldHandleBareKey(f(editable: true)), isFalse);
      expect(shouldHandleBareKey(f(quill: true)), isFalse);
      expect(shouldHandleBareKey(f(route: false)), isFalse);
    });

    test('modifier shortcuts ignore text focus but never a route above', () {
      final ctrlN = kShortcutDefs.firstWhere((d) => d.id == ShortcutId.newNote);
      expect(shouldHandleShortcut(ctrlN, f(editable: true)), isTrue);
      expect(shouldHandleShortcut(ctrlN, f(route: false)), isFalse);
    });

    test('text-guarded shortcuts are inert while typing', () {
      final del = kShortcutDefs.firstWhere(
        (d) => d.id == ShortcutId.trashSelected,
      );
      expect(shouldHandleShortcut(del, f(quill: true)), isFalse);
      expect(shouldHandleShortcut(del, f()), isTrue);
    });
  });

  test('no shortcut repeats while a key is held (no chained pops)', () {
    for (final d in kShortcutDefs) {
      for (final a in d.activators) {
        final repeats = switch (a) {
          SingleActivator() => a.includeRepeats,
          CharacterActivator() => a.includeRepeats,
          _ => false,
        };
        expect(repeats, isFalse, reason: '${d.id}');
      }
    }
  });
}
