# Backlog

Planning register; v1.3.2 implementation is explicitly authorized and in review. Later entries remain proposals unless separately approved. Product requirements: [REQUIREMENTS.md](REQUIREMENTS.md). Candidate release scopes: [ROADMAP.md](ROADMAP.md). Current preparation completed in [PR #8](https://github.com/mmoptibuilds-commits/notes-app/pull/8). Stable baseline v1.3.1, build 20261127. Planning base `e4c1769804f4bd8891638b1ad288122da36c10ea`.

The original inventory IDs H001–H108 and consolidated audit IDs A01–A24 remain stable. Audit rows overlap feature rows and are not additional independent implementation tasks. Evidence references came from the prior inventory; line numbers can drift, and reported bugs must be checked against the current tree. A proposed target is not a commitment. Use ready, in progress, blocked, in review and done only when a task has been explicitly authorized or evidence supports the status. Record owner, branch, base/head SHA and acceptance evidence in the linked issue or task handover; unassigned rows have no worker or branch yet.

## Feature inventory (108)


### Notes and editor

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H001 | Autosave gives up silently after 2000 failed tries | 1.3.2 | in review | Encrypted recovery rows, library review, restart recovery, and retry exhaustion are covered in `docs/handovers/v1.3.2.md`. | `test/ui/editor/editor_session_test.dart` |
| H002 | dispose() can skip its own cleanup | 1.3.2 | in review | Serialization failure and disposal cleanup are covered in `docs/handovers/v1.3.2.md`. | `test/ui/editor/editor_session_test.dart` |
| H003 | Empty Trash leaves image bytes in the database | 1.3.3 | proposed | A18: safe local/cloud cleanup must account for retained history, pending changes and other devices; defer destructive cleanup until proven. | lib/data/note_repository.dart:327-336 (purge keeps attachments), 339-350 (emptyTrash), 506-514 (collectUnusedAttachments), 604-611 (links rebuilt on save); test/data/note_repository_test.dart:307-309 (only callers); lib/data/migrations.dart:98-104 (attachments table) |
| H004 | Undo history is wiped when a checklist item moves | 1.4.0 | proposed | Undo and redo must include checklist toggles and completed-section moves. | lib/ui/editor/editor_session.dart:172-186 (_extract and _applyProjectionChange; history cleared at 185); docs/ARCHITECTURE.md:965 (documented limit) |
| H005 | Very long notes lay out every block up front | Validate / conditional | validate | Measure a long note on a device first (see the benchmark row). Build the lazy path only if the numbers justify it. | docs/ARCHITECTURE.md:947-950 (documented limit) |
| H006 | The library re-reads everything on each change | Validate / conditional | validate | Measure a large library first, then reload only the rows that changed. | lib/ui/library/library_controller.dart:192-231 (reload), called from lines 44, 131, 141, 147, 171 and 185 |
| H007 | Photos go in at full size | Validate / conditional | validate | Offer optional compression; preserve originals if chosen. Benchmark decoding and memory first. | lib/ui/editor/editor_screen.dart:350 (25 MB cap), 370-371 (cap check and message); lib/ui/editor/embeds.dart:81-86 (Image.memory without cacheWidth); pubspec.yaml (no image package) |
| H008 | Deleting a folder leaves dead folder ids on its notes | 1.5.0 | proposed | Clear folder_id in the same transaction as deleteFolder, then test a note whose folder was deleted. | lib/data/note_repository.dart:447-461 (deleteFolder), 208, 745, 749 (live-folder joins); docs/ARCHITECTURE.md:962-964 (documented limit) |
| H009 | Find in note: keyboard only, and no replace | 1.4.0 | proposed | Add a toolbar or menu entry for touch users. Build replace and replace-all on Document.replace. | lib/data/app_settings.dart:35-56 (ToolbarItem has no search item); flutter_quill 11.6.0 lib/src/editor/raw_editor/keyboard_shortcuts/default_single_activator_intents.dart:190-194 (Ctrl+F to OpenSearchIntent), editor_keyboard_shortcut_actions.dart:629-644 (opens the dialog), lib/src/toolbar/buttons/search/search_dialog.dart:128 (n/m count; no replace); lib/app.dart:105-107 (dialog localisation); flutter_quill document.dart:125 (replace); Everything App "Find in note" (shipped) and "Find bar has no replace" (upgrade) |
| H010 | Word and character counts | 1.5.0 | proposed | Count words and characters from the plain text the editor already builds (editor_session.dart:249-253). | No count code in lib/ui (grep); lib/ui/editor/editor_session.dart:249-253 (plainText); Everything App "Note details and stats" (shipped) |
| H011 | Note templates | 1.5.0 | proposed | Built-in and custom templates; storage representation is a design choice. | No template code in lib (grep); Everything App "Templates" (shipped) and "Templates are built in only" (upgrade) |
| H012 | Outline for long notes | 1.5.0 | proposed | Read the header attributes from the Delta and list them in a panel that jumps to each heading. | lib/ui/toolbar_item_info.dart:12-14 (heading labels); no outline code in lib (grep); Everything App "Outline navigation" (shipped) |
| H013 | Markdown typing shortcuts | 1.4.0 | proposed | Test the handlers on Android first. Enable the ones that pass, and write the rest with the same pattern. | flutter_quill 11.6.0 lib/src/editor/raw_editor/config/events/standard_char_shortcuts/block_shortcut_events_handlers.dart:10-46 (handlers); lib/src/editor/config/editor_config.dart:34 (default const []); lib/src/editor/raw_editor/config/events/space_shortcut_events.dart:10 (experimental); no spaceShortcutEvents in Notes lib (grep); Everything App "Markdown typing" (shipped) |
| H014 | Slash commands in the editor | Excluded | excluded | Excluded by owner. Keep existing library search shortcut. | lib/ui/shortcuts/shortcut_defs.dart:110-118 (slash binding, requiresNoTextFocus); lib/ui/shortcuts/shortcut_intents.dart:16-18; Everything App "Slash commands" (shipped) |
| H015 | Syntax highlighting in code blocks | 1.4.0 | proposed | Language labels, syntax highlighting, Copy and word-wrap controls; evaluate maintained dependencies. | pubspec.yaml (no highlighter package); Everything App "Syntax highlighting" (shipped) |
| H016 | Wiki links and backlinks (optional) | 1.5.0 | proposed | Accepted: searchable internal note links and backlinks in details; choose a compatible representation. | No wiki or backlink code in lib (grep); docs/PRODUCT.md:28 (links as formatting); Everything App "In-note wiki links" (shipped) and "Backlinks panel" (idea) |
| H017 | Note version history (your call) | 1.4.0 | proposed | Synchronized recoverable history; target latest 30 versions or 30 days subject to storage. Define exact retention before implementation; never prune pending operations. | No revision or history table in lib/data (grep); docs/DECISIONS.md:46 (D6, sync model); Everything App "Note version history" (idea) |
| H018 | Checklist filter in the library | 1.5.0 | proposed | Add a library scope for notes with open checklist items. note_card.dart already shows progress. | lib/data/models.dart:79 (NoteScope: active, archived, trash, conflicts); lib/ui/library/note_card.dart:349-350; Everything App "Checklists and tasks virtual folder" (shipped) |
| H019 | Minimal editor mode | 1.5.0 | proposed | Hide the toolbar and chrome until typing or selection, and store the choice in settings. | No minimal or focus mode in lib/ui (grep); lib/ui/settings/toolbar_settings_screen.dart; Everything App "Minimal note editor mode" (shipped) |
| H020 | Inline tables (your call) | Later | deferred | Accepted later, after stable editor; preserve existing format unless compatibility is proven. | flutter_quill 11.6.0 lib/src/packages/quill_markdown/utils.dart:23 (table type, Markdown only); lib/ui/editor/embeds.dart:93-94 (legacy tables shown as labels); docs/PRODUCT.md:26-30 (no tables listed); Everything App "Inline table widget" and "Table previews on note cards" (shipped) |
| H021 | Rich link cards (your call) | Later | deferred | Approved: on request, plus an automatic-preview toggle. Deferred pending privacy/network review. | docs/DECISIONS.md:180-181 (D18); no link fetch code in lib (grep); Everything App "Rich link cards" (shipped) |
| H022 | Auto-clear trash (your call) | Placement open | placement open | Accepted: automatic 30-day deletion with fresh 30-day grace for existing Trash. Candidate v1.9.0; no purge before backup/history/sync safety. | docs/PRODUCT.md:60 (Trash kept until emptied); Everything App "Auto-clear trash" (shipped) |
| H023 | Ctrl+C and Ctrl+X do nothing (not reproduced) | 1.4.0 | proposed | Previously passed manual verification. Reopen only if reproducible; keep regression coverage. | editor_screen.dart:164-165 (our Copy note action, not the key); grep of lib/ui/editor finds no copy or cut override; flutter_quill 11.6.0 research copy: default_clipboard_service.dart, standard_shortcut_events.dart |
| H024 | Copy and save images | 1.5.0 | proposed | Copy and save actions on image blocks. Write PNG to the clipboard. Test the save path on the laptop. | lib/ui/editor/embeds.dart:81-86 (image display) |
| H025 | Quote, code block and list usable together | 1.4.0 | proposed | Support compatible quote/list/code combinations only if existing format remains safe; otherwise retain format and explain limitation. | flutter_quill 11.6.0 attribute.dart:166-171 (exclusiveBlockKeys: header, list, code block, quote) |
| H026 | Folders as a dropdown on the main screen | 1.5.0 | proposed | A folder dropdown on the main screen. Keep the desktop sidebar. | lib/ui/widgets/responsive.dart:5-9 (desktop breakpoint 900 swaps the strip for the sidebar) |
| H027 | Pin and unpin in the overflow menu | 1.5.0 | proposed | Move the pin action into the existing overflow menu. | lib/ui/editor/editor_screen.dart:396-419 (app bar actions and PopupMenuButton) |
| H028 | Undo and redo in the top bar | 1.4.0 | proposed | Top-bar Undo/Redo on Android and desktop; optional toolbar duplicates. | lib/ui/editor/editor_toolbar.dart:275-292 (undo and redo items) |
| H029 | Note details panel | 1.5.0 | proposed | A details sheet built from the existing fields. Add anything missing as append-only columns. | grep finds no details UI in lib/ui; Everything App "Note details and stats" (inspiration only; no licence) |
| H030 | Arrow keys move through the note list | 1.5.0 | proposed | Bind up and down to list focus, Enter to open, then test keyboard-only navigation. | lib/ui/shortcuts/shortcut_defs.dart:140-162 (Alt+ArrowLeft is the only arrow binding) |

### Workspaces

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H031 | Separate workspaces | 1.7.0 | proposed | Separate workspace access, folders, search, Trash, history and optional chat. Agents have no personal-workspace access. | docs/PRODUCT.md:17 (folders flat), :53 (up to five devices, no accounts) |

### Agents: CLI and MCP

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H032 | CLI for agents | 1.7.0 | proposed | Use shared authenticated cloud API, not direct database access. CLI emits text and JSON. | github.com/HKUDS/CLI-Anything (Apache-2.0) |
| H033 | MCP server so every agent can connect | 1.7.0 | proposed | Shared API and remote MCP; optional STDIO adapter if needed. | pub.dev mcp_dart (MIT); github modelcontextprotocol/python-sdk (MIT, v2 current) |
| H034 | Agent workspace with notes and chat | 1.7.0 | proposed | External agents, channels, threads, DMs, mentions, attachments and offline message queue; no auto-wakeup. | Your request |

### Reminders and alerts

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H035 | Convert legacy reminders on import | 1.9.0 | proposed | Convert old reminder values on import and show what changed (legacy_backup.dart:92-99). | lib/importer/legacy_backup.dart:92-99 (reminderAt in unsupportedFields, line 95), 758 (carried list); lib/ui/help/help_topics.dart:184-186; docs/PRODUCT.md:83-84; docs/ARCHITECTURE.md:981-982 |
| H036 | Due time on a note | 1.9.0 | proposed | Add a nullable due-time column in the append-only schema. Update PRODUCT.md and the help text in the same change. | docs/PRODUCT.md:83-84; lib/ui/help/help_topics.dart:184-186; no reminder code in lib or pubspec.yaml (grep) |
| H037 | Done and Snooze buttons on reminder notifications | 1.9.0 | proposed | Wire the Done and Snooze callbacks, then test them on Android and Linux. | No notification code in lib (grep); Everything App "Reminders have no action buttons or snooze" (upgrade) |
| H038 | Tap a reminder to open its note | 1.9.0 | proposed | Put the note id in the payload, route it to the editor on tap, and test a cold start. | Everything App "Reminder deep-link" (shipped) |
| H039 | Exact alarms with an inexact fallback | 1.9.0 | proposed | Respect OS permissions and show fallback timing. | developer.android.com/about/versions/14/behavior-changes-all (exact alarms denied by default); developer.android.com/about/versions/14/changes/schedule-exact-alarms (USE_EXACT_ALARM) |
| H040 | Reminders on Linux (unverified) | 1.9.0 | proposed | Test on the laptop before promising reminders there. If delivery needs the app open, say so in the UI. | flutter_local_notifications 23.0.4 CHANGELOG.md:348 (old entry); flutter_local_notifications 23.0.4 README.md:928 (zonedSchedule takes a TZDateTime) |
| H041 | Reminders across several devices | 1.9.0 | proposed | Choose devices for each reminder; Done everywhere; Snooze current or all. | docs/PRODUCT.md:58 (what sync covers) |
| H042 | Two new dependencies for reminders (your call) | 1.9.0 | proposed | Select dependencies after platform verification and record in DECISIONS.md; no blanket dependency approval. | pubspec.yaml (neither package listed); flutter_local_notifications 23.0.4 README.md:928; your dependency rule |
| H043 | Calendar export (ICS, later) | Later | deferred | Write due dates to an .ics file later. Keep bill dates out (see the row). | Everything App "Calendar export (ICS)" (idea) |
| H044 | Push notifications on mobile and desktop | 1.9.0 | proposed | Reminder alerts on selected enabled devices; note-change notifications limited to selected agent workspaces or important events. Push conditional on zero new infrastructure spend. | docs/PRODUCT.md:53 (no always-on server); unifiedpush.org (needs a distributor server; Android and Linux) |

### Android, widgets and system

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H045 | Test predictive back on Android 16 | 1.9.0 | proposed | Test the back gesture and three-button navigation from the editor, a selection, search, sync and Trash. | android/app/build.gradle.kts:25 (targetSdk from Flutter); android/app/src/main/AndroidManifest.xml (no enableOnBackInvokedCallback); android/app/src/main/kotlin/com/mmoptibuilds/notes/MainActivity.kt (no back override); lib/ui/library/library_screen.dart:603-606 (PopScope); developer.android.com/about/versions/16/summary (predictive back default); developer.android.com/about/versions/16/behavior-changes-16 (temporary opt-out) |
| H046 | Monochrome launcher icon | 1.9.0 | proposed | Add a monochrome layer to the adaptive launcher icon, and test it on Android 13 or later. | No monochrome resource in android/app/src (grep); Everything App "Material You adaptive monochrome launcher icon" (shipped) |
| H047 | Launcher shortcuts | 1.9.0 | proposed | Add new note, new checklist and search as launcher shortcuts. Linux needs its own answer, which is not checked. | No shortcuts.xml or shortcut references in android/app/src (grep); Everything App "App launcher shortcuts" (shipped) |
| H048 | Home screen widgets | 1.9.0 | proposed | Quick capture, interactive checklist, pinned notes, single-note widget. Reminder and agent activity widgets later. | No AppWidget code in android/ or lib/ (grep); Everything App "Notes quick-capture widget" and "Checklist widget with multi-note cycling" (shipped) |
| H049 | Receive text and images from other apps | 1.9.0 | proposed | Add the SEND intent filters in AndroidManifest.xml, then route text and images into a new or existing note. | android/app/src/main/AndroidManifest.xml:33-43 (only MAIN/LAUNCHER and MY_PACKAGE_REPLACED filters); Everything App "Share into notes" (shipped) and "Shared images always open a note" (upgrade) |
| H050 | Send selected text from another app into a new note | 1.9.0 | proposed | Register a PROCESS_TEXT activity, route the selected text into a new note, and test it from another app's selection menu. | android/app/src/main/AndroidManifest.xml:55-60 (queries block only); Everything App "Process text action" (listed in its map) |
| H051 | Replace the deprecated activity result code | 1.9.0 | proposed | Move MainActivity off onActivityResult and onRequestPermissionsResult, then remove the suppress lines. | android/app/src/main/kotlin/com/mmoptibuilds/notes/MainActivity.kt:50 (startActivityForResult), 57-66 (onRequestPermissionsResult), 68-74 (onActivityResult) |
| H052 | Pin SDK levels in the repo | 1.9.0 | proposed | Pin SDK levels deliberately; retain Android 7 if safe and dependencies permit. Recheck actual SDK defaults. | android/app/build.gradle.kts:11, 24-25 (flutter.* values); Flutter 3.50 What's new post (Updated Android toolchain defaults) |
| H053 | Opt into AGP 9's new DSL once plugins allow | Validate / conditional | validate | Check each plugin, then remove the opt-outs in gradle.properties. | android/gradle.properties:3-6; Flutter 3.50 "What's new" post (AGP 9 new DSL support) |
| H054 | Other Android ABIs (your call) | 1.9.0 | proposed | Separate ARM64, ARM32 and x86_64 APKs where compatible; updater selects correct ABI. | README.md:164 (flutter build apk --target-platform android-arm64); docs/ARCHITECTURE.md:972-973 |
| H055 | Pull down from the top to sync | 1.9.0 | proposed | Wrap the note list and call the sync from onRefresh. | Your request |

### Desktop window

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H056 | Fullscreen button and F11 | 1.5.0 | proposed | A native method call for fullscreen on and off, F11 bound in Dart, and a button in the top bar. | linux/runner/my_application.cc:25-42 (window size and title; no fullscreen code) |
| H057 | Top bar in the app colours | 1.5.0 | proposed | Pick one approach and test it on the laptop (PRODUCT.md says GNOME on Wayland): a GTK header bar styled from the app, or a hidden native bar with our own top bar. | linux/runner/my_application.cc:32-39 (header bar commented out) |
| H058 | Hide and reposition sidebars | 1.5.0 | proposed | Show and hide, and a left and right swap, on top of the split view. Save the layout in settings. | lib/ui/library/desktop_sidebar.dart (sidebarWidth 232) |
| H059 | Ctrl+R syncs and refreshes | 1.5.0 | proposed | One binding that calls the sync and reloads the library. Check it does not collide with flutter_quill keys. | lib/ui/shortcuts/shortcut_defs.dart:92-162 (existing bindings) |

### Other platforms

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H060 | Browser client for iPhone | 1.8.0 | proposed | Online-first rich text and photos, existing cloud backend. Home Screen install and notifications if feasible for $0. | docs/PRODUCT.md:11 (keep iOS and web possible, do not build them), :77 (iOS and web builds excluded); earlier pass: Safari and Firefox have no raw TCP |

### Sync

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H061 | The receiver ignores the protocol and schema versions | 1.6.0 | proposed | Retire LAN after cloud parity and pending-record recovery; retain explicit version compatibility for supported installed cloud clients. | lib/sync/sync_session.dart:121-133 (hello sent with proto at 123 and schema at 126; receiver checks only the id at 131); docs/ARCHITECTURE.md:961 (documented as not enforced) |
| H062 | A full quarantine table blocks a peer's batches | 1.3.3 | proposed | A06/A13: retain and expose quarantined records, isolate failures and scope cleanup. LAN removal must not erase unresolved edits. | lib/sync/peers.dart:13-16 (limits and failure rule), 262-263 (throw when full), 296-298 (removal only after applying), 300-301 (quarantined() has no caller); lib/ui (no quarantine screen, grep); docs/ARCHITECTURE.md:559-563 |
| H063 | Reach peers that discovery cannot see | Excluded | excluded | No new LAN discovery features. | lib/sync/sync_service.dart:651-656 and 693-694 (broadcast discovery); lib/ui/sync/pair_screen.dart:264-269 (paste box is the only peer input); docs/ARCHITECTURE.md:953-954 (no routed subnets), 984-985 (Tailscale not verified); docs/PRODUCT.md:61 (Tailscale addresses); Everything App "Hotspot and multi-subnet discovery" and "Fast /24 HTTP subnet peer scanner" (shipped) |
| H064 | IPv4 only | Excluded | excluded | No new LAN discovery features. | lib/sync/sync_service.dart:104 (listener on anyIPv4), 654 (discovery), 693 (broadcast socket), 759 (IPv4 address type); docs/ARCHITECTURE.md:953-954; Everything App "Resilient IPv6 local discovery" (shipped) |
| H065 | Periodic background sync (your call) | Placement open | placement open | Accepted: battery-aware periodic Android background sync; candidate v1.9.0. No guarantee of exact scheduling. | docs/PRODUCT.md:57; docs/ARCHITECTURE.md:955-956; Everything App "Periodic interval sync" (shipped) |
| H066 | Sync between devices that are never online together (your call) | Already available | done | Cloud sync already supports non-overlapping online times. | docs/ARCHITECTURE.md:951-952 (no relay); docs/PRODUCT.md:62-63 and 77; Everything App "Offline P2P mailbox sync" and "Cross-network E2EE blind relay sync" (shipped) |
| H067 | Offline edits merge, with no conflict copies | 1.6.0 | proposed | Automatic merge with deterministic ordering, no lost edits; keep recoverable history and test OT/CRDT. | lib/sync/merge.dart:10-17, 75-76, 177-184 (note-level winner and conflict copy); Google Drive 2010 post on operational transformation |
| H068 | Pull on a short timer while the app is open | 1.6.0 | proposed | Existing foreground cloud polling; investigate open editor updates before tuning. | lib/app.dart:40-93 (triggers); lib/sync/sync_service.dart:520-556 (backoff and debounce) |
| H069 | Syncing works from the phone but not from the laptop | Validate / conditional | validate | Old LAN report; retest cloud only if still reproducible. | lib/sync/sync_service.dart:651-686 (discovery swallows SocketException); lines 19-20 (ports) |

### Import and export

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H070 | Import encrypted Notebook backups | Excluded | excluded | Excluded by owner; do not implement encrypted legacy Notebook import. | lib/importer/legacy_backup.dart:540-549 (refusal and message); docs/ARCHITECTURE.md:364-365 (detection fields only); docs/DECISIONS.md:94 (D12) |
| H071 | Markdown export drops formatting | 1.9.0 | proposed | Keep an extra format next to Markdown, or say on the export screen what gets lost. | docs/ARCHITECTURE.md:983 (documented limit); docs/PRODUCT.md:72 (Markdown export of single notes) |
| H072 | Bulk Markdown export as a ZIP | 1.9.0 | proposed | One ZIP with each note as a .md file, and attachments in a folder. | lib/ui/data/data_screen.dart:413-416 (JSON export of all notes); lib/ui/editor/editor_screen.dart:183-214 (single-note Markdown save); archive 4.7.1 LICENSE and lib/src/codecs/zip_encoder.dart; Everything App "Notes export has no bulk option" (upgrade) |
| H073 | Google Keep import | Excluded | excluded | Excluded by owner; do not implement Google Keep import. | lib/importer/markdown_import.dart (Markdown import); lib/importer/legacy_backup.dart (Notebook JSON); no Keep importer in lib/importer (grep); Everything App "Google Keep and Markdown import" and "Fast Google Takeout import" (shipped) |
| H074 | Export settings with the data (your call) | 1.9.0 | proposed | Optional non-secret settings only, never credentials. | lib/importer/notes_export.dart (no settings fields, grep); lib/ui/data/data_screen.dart:413-416; Everything App "Complete settings export" (shipped) |
| H075 | Share sheet and plain-text export for one note | 1.9.0 | proposed | Add the share sheet on Android. On Linux, export through a save dialog (not checked). | lib/ui/editor/editor_screen.dart:164-167 (copy plain text), 178-181 (copy Markdown), 183-214 (save .md); no share code in lib or android (grep); pubspec.yaml (no share package); Everything App "Share and export" (shipped) |

### Security and data

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H076 | Restore snapshots pile up forever | 1.3.2 | in review | Import snapshots retain at most seven verified copies; unverified files are left alone. | `test/data/app_database_test.dart` |
| H077 | Optional passphrase on the JSON export | 1.9.0 | proposed | Offer encrypted backup alongside readable JSON; verify restore. | lib/ui/data/data_screen.dart:416 (not encrypted); docs/DECISIONS.md:44 (D5); pubspec.yaml:45 (cryptography ^2.9.0); cryptography 2.9.0 source (src/dart/argon2.dart, src/dart/xchacha20.dart) |
| H078 | Printable recovery key (your call) | Later | deferred | Defer recovery key until backup improvements are stable. | docs/ARCHITECTURE.md:966-967 (documented); no recovery key code in lib (grep); Everything App "Recovery key for auto-backups" |
| H079 | Screenshot shield on note screens (your call) | Excluded | excluded | Excluded by owner; no screenshot shield. | No FLAG_SECURE or window flags in android/app/src or lib (grep); Everything App "Screenshot shield" (shipped) |
| H080 | Scheduled encrypted backups | 1.9.0 | proposed | Daily or weekly, chosen folder, keep seven verified backups. | No backup scheduler in lib (the only Timer.periodic is the pairing tick, lib/ui/sync/pair_screen.dart:114); Everything App "Encrypted auto-backups" (shipped) |
| H081 | Update checks fail without saying why | 1.3.2 | in review | Safe retry guidance and HTTP/update failure cases are covered in the updater handover. | `docs/handovers/v1.3.2-updater.md` |
| H082 | The too-new database message leaves out the rollback copy | 1.3.2 | in review | Startup recovery guidance points to the expected pre-migration backup; path and short-screen widgets pass. | `test/ui/startup_error_test.dart` |

### Look, feel and settings

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H083 | Theme does not follow the system | 1.5.0 | proposed | System-following option plus true AMOLED default, charcoal and light. | lib/data/app_settings.dart:10 (AppTheme enum); lib/ui/theme/app_theme.dart:183-186 (dark chosen from the app setting only); Everything App "Editor theme that follows the system theme" (shipped) |
| H084 | Haptics on more than one action | 1.5.0 | proposed | Add haptics to checklist ticks, pin and delete, behind a setting. | lib/ui/library/library_screen.dart:326-327 (the only HapticFeedback call); Everything App "Haptics everywhere" and "Tactile haptics preferences" (shipped) |
| H085 | The system reduce-motion setting is ignored | 1.3.2 | in review | System reduced motion disables app motion without changing the saved setting; see S5 handover. | `docs/handovers/v1.3.2-s5.md` |
| H086 | Localisation (your call) | Later | deferred | English only; no localization work planned. | pubspec.yaml (no intl or flutter_localizations); lib/app.dart:107 (only Quill's localisation delegate); Everything App "Full Russian localisation", "Tamil language support" and "Per-app language settings" (shipped) |
| H087 | Material 3 Expressive styling (your call) | 1.5.0 | proposed | Selective Material 3 Expressive components only where helpful. | No expressive or morphing code in lib (grep); Everything App "Material 3 Expressive design system", "Wavy slider" and "Morphing action buttons" (shipped) |
| H088 | Dithered background | 1.5.0 | proposed | Optional toggle if inexpensive. | pub.dev material_palette (MIT; 1.6.0; Linux listed); earlier pass: Bayer dither wrap shader |
| H089 | Tiny animations and interactions | 1.5.0 | proposed | Pick the motions. Gate each one on the animation setting, which must also honour the system reduce-motion flag. | pub.dev flutter_animate (BSD-3-Clause; 4.5.2; Android, iOS, Linux, macOS, web, Windows) |
| H090 | Free components from the web | 1.5.0 | proposed | Only if measurable benefit and suitable license. | pub.dev forui (page lists OFL-1.1 and MIT; Linux listed; 0.27.7) |
| H091 | Second accent colour | 1.5.0 | proposed | A second accent token, a picker in settings, and theme wiring. | lib/ui/theme/app_theme.dart:56-189 (one accent per palette; secondary is the accent) |
| H092 | Device colour as the accent | 1.5.0 | proposed | Show the option only where the platform gives a colour. Test on the phone and the laptop. | pub.dev dynamic_color (Apache-2.0; Android (S+), Linux, macOS, Windows; 2.1.0) |
| H093 | Different splash for fresh install and normal launch | 1.5.0 | proposed | Separate short first-install motion intro if feasible; asset production separate from app work. Ordinary launch stays fast. | lib/app.dart:44-49 (onboarding completes when data exists); lib/ui/splash.dart:64 |
| H094 | What's-new popup after an update | 1.5.0 | proposed | Store the last-seen version. Show the popup once when it changes, from the release notes. | docs/RELEASE_NOTES.md:7 (What's new section) |
| H095 | In-app changelog | 1.5.0 | proposed | Generate the changelog at release time, bundle it, and show it on a screen. | docs/RELEASE_NOTES.md:7; github orhun/git-cliff (dual Apache-2.0 or MIT) |

### Repo, release and docs

| ID | Item | Candidate target | Status | Decision / next action | Historical evidence |
| --- | --- | --- | --- | --- | --- |
| H096 | DECISIONS.md D3 dates the deprecation to 3.47 | Prep | verify / proposed | Verify remaining D3 correction against current pinned SDK; tooling preparation did not change DECISIONS.md. | docs/DECISIONS.md:15-20 (D3, line 16); Flutter 3.50 What's new post (deprecations section); flutter.dev/blog/whats-new-in-flutter-3-47 (material_ui on pub.dev); lib/ui/material.dart:5-8 (the barrel) |
| H097 | DECISIONS.md D4 still says arm64 is unverified | Prep | verify / proposed | Verify and correct D4 with actual device evidence; not marked complete by tooling merge. | docs/DECISIONS.md:22-29 (D4, line 29); README.md:106-108 (device check) |
| H098 | DECISIONS.md D7 is wrong for restores | Prep | verify / proposed | Correct D7 only after checking restore semantics; behavior changes require separate approval. | docs/DECISIONS.md:66-70 (D7); lib/importer/legacy_backup.dart:1003 (local clock), 1013 (version vector increment) |
| H099 | DECISIONS.md D15 says the newest 500 rows are kept | Prep | verify / proposed | Correct D15 to reflect actual quarantine behavior; coordinate A06/A13. | docs/DECISIONS.md:137 (D15 finding 5); lib/sync/peers.dart:262-263 (throw), 296-298 (removal only after applying) |
| H100 | CI builds nothing | Already available | done | Manual release-build workflow existed; Worker CI added in PR #8. | .github/workflows/ci.yml:29-45 (steps); docs/ARCHITECTURE.md:866-867; README.md:163-164 (build commands that CI does not run) |
| H101 | CI does not enforce the lockfile | Prep | done | Lockfile enforcement added in PR #8. | .github/workflows/ci.yml:29-30 ("Resolve dependencies" step) |
| H102 | Lint suppressions hide deprecations and an internal import | 1.4.0 | proposed | Prefer public API for Quill; document any necessary private import and targeted lint suppression. | lib/ui/material.dart:7; lib/ui/editor/editor_screen.dart:11-12 |
| H103 | Turn on more lints | Validate / conditional | validate | Do not broadly change lint rules unless justified. | analysis_options.yaml:10 (include), 29-31 (rules block, all commented out) |
| H104 | Record release benchmarks for long notes and big libraries | 2.0.0 | proposed | Measure a long note and a big library on a device, and record the numbers with the build they came from. | docs/PERFORMANCE.md:5-6, 100-102; docs/ARCHITECTURE.md:947-950 |
| H105 | Upgrade sqlite3 to 3.9.2, after an encrypted-database test | 1.3.2 | evaluated; defer | Keep 3.9.1 until encrypted database compatibility is verified on Android arm64 and Linux; see S5 handover. | `docs/handovers/v1.3.2-s5.md` |
| H106 | Two packages with no release since 2023 | Validate / conditional | validate | Check open issues on each one, then keep, fork or replace it. | pubspec.yaml:42, 46; lib/ui/library/library_screen.dart:5; lib/ui/sync/pair_screen.dart:6, 151; pub.dev package pages (checked 2026-11-23) |
| H107 | Hardware checks still open | 2.0.0 | proposed | Actual updater and relevant physical devices remain gates for every release; no Tailscale work. | docs/ARCHITECTURE.md:984-987; README.md:106-110 |
| H108 | Releases grouped by theme | Prep | verify / proposed | Theme-based release notes are useful; automated changelog tool and commit-prefix enforcement remain optional proposals, not approved requirements. | Your request; release steps in docs/RELEASE.md |

## Consolidated audit findings (24)

| ID | Finding | Priority / candidate target | Status | Next action |
| --- | --- | --- | --- | --- |
| A01 | Duplicate local sequence numbers | Critical 1.3.2 | in review | Two writer processes now refresh sequence and HLC metadata under the SQLite write lock; see root handover. |
| A02 | Migration backup rotation | Critical 1.3.2 | in review | Backup replacement is verified and atomic; a failed replacement retains the previous copy. |
| A03 | Autosave abandons text | Critical 1.3.2 | in review | Encrypted pending drafts survive restart and exhaustion; see root handover. |
| A04 | Editor disposal cleanup | High 1.3.2 | in review | Cleanup runs after serialization failure; see root handover. |
| A05 | Linux archive path validation | Critical 1.3.2 | reproduced; in review; [#9](https://github.com/mmoptibuilds-commits/notes-app/issues/9) | Jammy and Noble mawk reproduce the parser failure; both accept the valid fixture and reject hostile fixtures with the fix. |
| A06 | LAN quarantine deletion | Critical 1.3.2 | in review | Cloud quarantine limits now preserve unrelated LAN entries and retry unreadable pages; see S4 worker evidence. |
| A07 | Cloud page of 51 | Critical 1.3.3 | validate / proposed | Server pagination can produce more=true at head; add boundary regression. |
| A08 | Attachment download >192 KiB | Critical 1.3.3 | validate / proposed | Chunk completion mismatch can stop after first chunk. |
| A09 | More than 100 hashes | High 1.3.3 | validate / proposed | Batch attachment hash checks for initial upload and join. |
| A10 | Interrupted initial upload | High 1.3.3 | validate / proposed | Recover safely after reinstall/sign-out or lost uploader identity. |
| A11 | Legacy note identifiers | High 1.3.3 | validate / proposed | Validate compatibility and preserve existing references. |
| A12 | Request body size | High 1.3.3 | validate / proposed | Measure serialized payload instead of underestimating overhead. |
| A13 | Conflict row blocks uploads | High 1.3.3 | validate / proposed | Quarantine safely and continue; never discard unresolved data. |
| A14 | Library re-link | High 1.3.3 | validate / proposed | Provide explicit recovery without wiping local data. |
| A15 | Retry backoff bypass | High 1.3.3 | validate / proposed | Respect retry delays and avoid needless compute. |
| A16 | Oversized row blocks cursor | Medium 1.3.3 | validate / proposed | Record blocked row in recoverable retry state; continue valid changes. |
| A17 | All image bytes read on sync | Medium 1.3.3 | validate / proposed | Query metadata before loading only needed bytes. |
| A18 | Orphaned attachments | Medium 1.3.3 | validate / proposed | Safe garbage collection with revision and sync reference checks. |
| A19 | Quadratic blob appends | Medium 1.3.3 | validate / proposed | Benchmark, then evaluate object storage or chunking. |
| A20 | Worker CI missing / duplicate tests | Engineering Prep | done (PR #8) | Add server tests, remove duplicated Flutter runs and enforce lockfile. |
| A21 | Backup and transfer memory | Measure first 1.9.0 / 2.0.0 | validate / proposed | Measure large libraries, imports and exports before streaming changes. LAN-only work superseded. |
| A22 | Private Quill imports / stale docs | Engineering 1.4.0 / Prep | validate / proposed | Use stable public API where practical; avoid unrelated refactor. |
| A23 | Release safeguards | Verify 1.3.2 / 2.0.0 | verify existing safeguards | Existing update save barrier, export warning, manual build and branch protection previously reported done; verify rather than rebuild. Independent offline signing-key recovery. |
| A24 | Performance / dependency hygiene | Measure first 2.0.0 | validate / proposed | Benchmark long notes, full-library reloads and image decoding; selective dependency changes only. |

## Additional requirements not represented by a standalone inventory row

| ID | Item | Candidate target | Status / acceptance |
| --- | --- | --- | --- |
| R01 | Ctrl+Up/Down, last-line Down, Linux vertical drag selection, formatting focus and keyboard regression matrix | 1.4.0 | Proposed; reproduce reported issues, preserve Ctrl+A/C/X, Shift-selection, paste and touch |
| R02 | Android editor toolbar customization and quick settings | 1.5.0 | Proposed; long press reorder/hide/reset |
| R03 | Library/editor backgrounds, device default and optional per-note override | 1.5.0 | Proposed; solid, gradient and image, retain contrast |
| R04 | Live open-note updates, presence, deterministic merge and recovery | 1.6.0 | Proposed; H067/H068; 1–3s target conditional |
| R05 | Agent identity, authorization, offline message queue, DMs and mentions | 1.7.0 | Proposed; H031–H034; private workspace inaccessible |
| R06 | Windows desktop then responsive iPad web layout | 1.8.0 | Proposed; actual platform tests |
| R07 | Cross-device reminder targeting and four Android widgets | 1.9.0 | Proposed; H041/H048 |
| R08 | Public offline distribution | 2.0.0 | Conditional; no dependency on private backend; self-hosted sync separately evaluated |
| R09 | Optional original-preserving image compression | Validate / conditional | H007/A24; benchmark first |
| R10 | Open-note and library performance, large backup memory | Measure first | A21/A24; benchmark before changing architecture |
| R11 | Android periodic background sync and auto-trash | Placement open | H065/H022; candidate 1.9.0 |
| R12 | Remove LAN completely | 1.6.0 | H061/H067; cloud parity and recovery first |

## Tracking and reconciliation

- Preparation is complete. H096–H099 and H108 are not claimed completed by PR #8; verify and place any remaining work in the appropriate release.
- H023 was previously reported fixed; regression-test rather than blindly reimplement. A05 remains open despite general updater checks passing.
- The historical audit results are not fresh reproductions. Tooling candidate reported 1,668 Flutter passes, seven skips and 25 Worker passes; both main CI jobs passed. Re-establish baseline for each release.
- Link new tasks to [HANDOVER.md](HANDOVER.md). Do not create duplicate work for overlapping IDs. Update this register after verified changes. Add new ideas without changing existing IDs.
