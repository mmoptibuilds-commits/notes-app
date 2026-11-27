---
name: notes-ui-qa
description: Verify Notes UI changes across phone and desktop layouts, themes, keyboard behaviour and accessibility.
---

- Follow [Visual review](../../../docs/DEVELOPMENT.md#visual-review). Cover narrow portrait and landscape, desktop including a small window, all three themes, and increased text scale. For library changes, exercise grid, masonry and list. Check for overflow and 48 dp Android touch targets.
- Check Tab and Shift+Tab, visible focus, Escape layering, and that bare shortcuts stay inactive in text fields and dialogs. Check Ctrl+S inserts no character, labelled controls and headings expose semantics, and motion respects the setting.
- Use synthetic data, widget screenshots and a disposable emulator when native insets matter. Keep review captures in `build/screens/` unless intentionally updating README images. Check onboarding leaves the library empty when that flow changes.
- Run formatting, analysis and the affected widget tests. Record sizes, themes, input modes and anything left unverified.
