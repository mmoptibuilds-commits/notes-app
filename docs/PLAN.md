# Plan

Status words: **done** (implemented and verified, evidence listed),
**partial**, **not started**, **blocked** (says on what).
Update this file at every checkpoint. Evidence means a command and its result.

## Current position

Milestone 1 done. Milestone 2 data layer done and tested; keystore bootstrap
still open. **Next action:** platform bootstrap (key storage, data dir), then
milestone 3 UI.

## Waiting on the user

- Approve Android SDK licence acceptance (needed for any APK build).
- Real backup file and reference screenshots into `private/`.
- Phone connected over USB with debugging on (real-device checks).
- Written scope of the upstream author's permission (before publishing).

## Milestones

### 1. Environment and foundation — done
- [x] Flutter 3.50.0, cmake, ninja installed; `flutter doctor` green for Linux.
- [x] Project created in place; `flutter build linux --release` succeeds.
- [x] Encrypted SQLite + FTS5 verified by test on Linux.
- [x] Harness docs.
- [ ] Android SDK + JDK 17 (blocked: licence approval).

### 2. Database, note model, CRUD — partial
- [x] Schema v1 with sync metadata, migration runner, upgrade test harness.
- [x] `NoteRepository`: create, save content, pin, archive, move, trash,
      restore, purge, folders, search, attachments, conflict copies.
- [x] Encrypted open; wrong or missing key refused without touching the file.
- [ ] Key in the platform keystore; refuse to start if the key is missing.
- Accept: create → edit → close DB → reopen returns identical content;
  killed mid-transaction leaves the previous state.

### 3. Library, editor, themes — not started
- Accept: three themes, three layouts, fonts, text size, animation level;
  new note opens instantly; autosave; restart keeps content; library scroll
  position restored; screenshots reviewed against references.

### 4. Checklists, formatting, folders, search, navigation — not started
- Accept: completed-section projection round-trips byte-identically;
  restore/delete/bulk actions; opening a note writes nothing; search over a
  large synthetic library stays fast (measured).

### 5. Legacy import/export — not started
- Accept: synthetic fixture imports fully; re-import adds nothing; modified
  note is not overwritten; rollback works; interrupted import leaves no
  partial state; private run matches 84 records (42 active, 2 archived,
  40 deleted) by count and hash.

### 6. Pairing and sync — not started
- Accept: two in-process peers converge under reordering, duplication and
  disconnects; concurrent edits produce a conflict copy on both sides;
  purge/trash rules hold; tampered or replayed frames are rejected; two real
  devices sync both ways.

### 7. Packaging and release validation — not started
- Accept: signed release APK installs beside the legacy app and upgrades
  without data loss; Linux bundle with desktop entry; measured startup,
  memory, scroll, search and typing figures recorded here.

## Verification log

| Date | What | Command | Result |
|---|---|---|---|
| 2026-11-17 | Linux toolchain | `flutter doctor -v` | Linux toolchain ✓, Android ✗ (no SDK) |
| 2026-11-17 | Encrypted DB + FTS5 | `flutter test test/spike/sqlite_spike_test.dart` | pass; SQLite 3.54.0, cipher chacha20, fts5 true |
| 2026-11-17 | Linux release build, path with space | `flutter build linux --release` | built `bundle/notes`, `libsqlite3mc.so` bundled |
| 2026-11-17 | Core + data layer | `flutter analyze && flutter test` | no issues; 41 tests pass |
