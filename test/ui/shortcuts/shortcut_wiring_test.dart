import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/shortcuts/shortcut_defs.dart';
import 'package:notes/ui/shortcuts/shortcut_guards.dart';

/// Counts how often each shortcut's handler ran.
class _Counts {
  final Map<ShortcutId, int> n = {};
  VoidCallback h(ShortcutId id) =>
      () => n[id] = (n[id] ?? 0) + 1;
  int of(ShortcutId id) => n[id] ?? 0;
}

Future<void> _tap(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

Future<void> _ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Map<ShortcutId, VoidCallback> _all(_Counts c) => {
  for (final d in kShortcutDefs) d.id: c.h(d.id),
};

void main() {
  testWidgets('bare slash is handled with no focus, inert in a TextField', (
    tester,
  ) async {
    final c = _Counts();
    final focus = FocusNode();
    final field = FocusNode();
    addTearDown(() {
      focus.dispose();
      field.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: shortcutScope(
          scopes: {ShortcutScope.library, ShortcutScope.global},
          handlers: _all(c),
          child: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: focus,
                  autofocus: true,
                  child: const SizedBox(),
                ),
                TextField(focusNode: field),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(
      LogicalKeyboardKey.slash,
      physicalKey: PhysicalKeyboardKey.slash,
    );
    await tester.pump();
    expect(c.of(ShortcutId.slashSearch), 1);

    field.requestFocus();
    await tester.pump();
    await _tap(tester, LogicalKeyboardKey.slash);
    expect(
      c.of(ShortcutId.slashSearch),
      1,
      reason: '/ must not fire in a field',
    );
  });

  testWidgets('Delete is inert while a TextField has focus', (tester) async {
    final c = _Counts();
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: shortcutScope(
          scopes: {ShortcutScope.library},
          handlers: _all(c),
          child: Scaffold(body: TextField(focusNode: field)),
        ),
      ),
    );
    field.requestFocus();
    await tester.pump();
    await _tap(tester, LogicalKeyboardKey.delete);
    expect(c.of(ShortcutId.trashSelected), 0);
  });

  testWidgets('Ctrl+N still works while a TextField has focus', (tester) async {
    final c = _Counts();
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: shortcutScope(
          scopes: {ShortcutScope.library},
          handlers: _all(c),
          child: Scaffold(body: TextField(focusNode: field)),
        ),
      ),
    );
    field.requestFocus();
    await tester.pump();
    await _ctrl(tester, LogicalKeyboardKey.keyN);
    expect(c.of(ShortcutId.newNote), 1);
  });

  testWidgets('Quill focus blocks bare keys, Ctrl+S saves without typing', (
    tester,
  ) async {
    final c = _Counts();
    final controller = QuillController.basic();
    addTearDown(controller.dispose);
    final focusNode = FocusNode();
    final scroll = ScrollController();
    addTearDown(() {
      focusNode.dispose();
      scroll.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: shortcutScope(
          scopes: {ShortcutScope.editor, ShortcutScope.global},
          handlers: _all(c),
          child: Scaffold(
            body: QuillEditor(
              focusNode: focusNode,
              scrollController: scroll,
              controller: controller,
              config: const QuillEditorConfig(scrollable: false),
            ),
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();
    final before = controller.document.toPlainText();

    await _tap(tester, LogicalKeyboardKey.slash);
    expect(c.of(ShortcutId.slashSearch), 0, reason: '/ must not fire in Quill');

    await _ctrl(tester, LogicalKeyboardKey.keyS);
    expect(c.of(ShortcutId.saveNow), 1);
    expect(
      controller.document.toPlainText(),
      before,
      reason: 'Ctrl+S must not insert a character',
    );
  });

  testWidgets('modifier shortcuts are inert while a dialog is open', (
    tester,
  ) async {
    final c = _Counts();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => shortcutScope(
            scopes: {ShortcutScope.library, ShortcutScope.global},
            handlers: _all(c),
            child: Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(title: Text('Dialog')),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _ctrl(tester, LogicalKeyboardKey.keyN);
    await _ctrl(tester, LogicalKeyboardKey.comma);
    expect(c.of(ShortcutId.newNote), 0);
    expect(c.of(ShortcutId.openSettings), 0);
  });

  testWidgets('Ctrl+K is not bound while it has no UI', (tester) async {
    final c = _Counts();
    await tester.pumpWidget(
      MaterialApp(
        home: shortcutScope(
          scopes: {ShortcutScope.global},
          handlers: _all(c),
          child: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    await _ctrl(tester, LogicalKeyboardKey.keyK);
    expect(c.of(ShortcutId.quickNav), 0);
  });
}
