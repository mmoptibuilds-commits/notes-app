# Plan

Status words: **done** (implemented and verified, evidence listed),
**partial**, **not started**, **blocked** (says on what).
Update this file at every checkpoint. Evidence means a command and its result.

## Current position

Done and verified: data layer, editor, checklist projection, legacy importer /
export / markdown (merged from worker branch), sync merge, secure channel,
sync session, TCP + pairing + `SyncService` (tested over real loopback sockets).
In flight: library + settings UI worker `a08f7a73b3e20d67e`
(branch `worktree-agent-a08f7a73b3e20d67e`, resumed after the usage limit).

**Next actions (lead):**
1. Merge the library/settings branch when its gates pass; review its diff.
2. Sync UI: Settings → Sync section (device list, status, sync now, pair via
   QR show / scan / paste, remove device, device name); wire `SyncService`
   into `bootstrap`/`AppScope`, auto-sync on open/resume and after edits.
   Needs `qr_flutter` and `mobile_scanner` (decisions to record).
3. Import UI (settings → Data): pick backup file, report, rollback; export.
4. Independent security review of `lib/sync/secure_channel.dart`,
   `pairing.dart`, `sync_session.dart`, `tcp_transport.dart`.
5. Android SDK (needs user's licence approval), APK build, device checks.

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

### 3. Library, editor, themes — partial
- [x] Editor screen, toolbar (user-configurable), completed section, autosave (done, widget-tested).
- [ ] Library + settings screens (worker `a08f7a73b3e20d67e`, interrupted).
- Known limitation: checking or restoring a checklist item clears the editor's undo
  history (undo across a moved line would act on shifted text).
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

### 6. Pairing and sync — partial (engine done; UI, discovery on real LANs and devices pending)
- [x] Merge rules and `RemoteApplier` (pure Dart): symmetric merge, conflict
      copies, delete-vs-edit, per-field metadata, clock-skew guard.
      Verified: 25 tests incl. randomised 3-device convergence (8 seeds).
- [x] Device identity, peers table (5-device cap), Noise-style handshake with
      directional keys and per-frame counters, one-time-code pairing,
      session protocol (cursors, atomic apply, hash-checked images), TCP
      transport, `SyncService` with back-off and UDP discovery.
      Verified: 17 channel security tests, 19 session tests (incl. connection
      cut at every frame, hostile peers), 12 service tests over real sockets.
- [ ] Sync UI, QR scanning (Android camera: unverified), discovery on a real
      LAN (unverified), Tailscale (unverified: not installed), two real devices.
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
| 2026-11-17 | Editor session + screen | `flutter analyze && flutter test` | no issues; 85 tests pass (property tests for checklist projection; widget tests tick/restore/undo-delete/toolbar/trash) |
| 2026-11-17 | Sync merge + convergence | `flutter test test/sync` | 25 pass; 3 devices, skewed clocks, dup/drop/reorder, 8 seeds converge |
| 2026-11-17 | Linux release smoke | `flutter build linux --release`; run 8 s with `NOTES_DATA_DIR` | builds, starts, creates encrypted `notes.db` (header not plaintext) |
| 2026-11-17 | Legacy importer/export/markdown merged | `flutter analyze && flutter test` on main | no issues; 198 pass, 1 skipped (private-backup test, no file present) |
| 2026-11-17 | Sync stack | `flutter test test/sync` | 81 pass: secure channel, session fault injection, loopback pairing + sync |
| 2026-11-17 | Data-layer timings (Dart VM/JIT via `flutter test test/perf`, encrypted DB, NOT release) | 5,000 notes × ~1.5 KB | create all 2.7 s (one transaction); list all 66 ms; search 54–62 ms for words matching every note (200 hits + 60 snippets), 0.5 ms for none; counts 38 ms; small-note save 0.56 ms |
| 2026-11-17 | Long note (VM) | one 1.15 MB note | create 62 ms, digest 17 ms, save 90 ms, search 2 ms. Found and fixed: SQLite `snippet()` took 2,419 ms on it; snippets are now built in Dart from a 150-char window |
