---
name: notes-ui-qa
description: Verify Notes UI changes: layout at several window sizes and text scales, themes, keyboard behaviour, accessibility semantics, and synthetic-data screenshots. Use after changing anything under lib/ui/.
---

# Notes UI QA

Run from the repo root with `export PATH="$HOME/development/flutter/bin:$PATH"`.

1. Gates: `dart format --output=none --set-exit-if-changed lib test tool`, `flutter analyze` (No issues found), `flutter test`.
2. Layout matrix (widget tests via `tester.view.physicalSize`/`devicePixelRatio` and `MediaQuery` text scaler): 360x640 portrait, 800x360 landscape, 768x1024, Linux 640x480, 1024x768, 1920x1080; text scale 1.0 and 1.4 (settings.textScale and system scaler); themes AMOLED, charcoal, light; layouts grid, masonry, list. Assert no `tester.takeException()` (overflow) and that targets measure >= 48dp on Android widths.
3. Keyboard: Tab/Shift+Tab order, visible focus, Escape layering (popup, dialog, search/selection, back), `/` and Delete never act while the Quill editor is focused or a dialog is open, Ctrl+S inserts no character.
4. Semantics: `tester.ensureSemantics()`; icon-only controls have labels/tooltips; headings are marked.
5. Reduced motion: AnimationLevel.off/reduced yields no running transitions.
6. Screenshots: synthetic data only, via `test/support/screenshot.dart`; keep temporary review PNGs outside the tracked repo. README assets are the exception: `test/visual/review_screens_test.dart` writes the selected phone and desktop renders to `docs/screenshots/`; inspect them before committing. Never use real notes.
7. Data safety: UI work must not write notes; onboarding never creates sample notes; run `test/data/onboarding_state_test.dart`.
