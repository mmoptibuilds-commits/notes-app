# Product and engineering requirements

Accepted owner decisions from the roadmap discussions, organized by domain rather than questionnaire number. Release placement and technical implementation remain proposals until approved. This is a future requirements register, not a description of already shipped behavior. Where an exact design was not settled, keep the choice open rather than assuming approval.

## Product and safety

- Primarily one human owner and their agents; a free public offline edition if feasible, with users supplying their own sync server if desired. Do not build a hosted multi-user commercial service.
- Target v2.0 before December 31, 2026, without trading away stability; necessary/easy work first, parallel agents for independent tasks, sequential verified releases.
- Critical data integrity, security and basic editor correctness precede features. Small fixes use patch versions. Keep the current stack and use targeted refactors and dependency upgrades only when justified.
- Cloud server may read notes for merging; no end-to-end encryption claim. Google sign-in for human owner; five human devices, separate agent connections.
- No additional spending. Existing subscriptions and prepaid balances allowed when useful; no new credit purchases. No private account details in repository.
- No app lock or screenshot protection. Maintain independent secure signing-key backup and tested recovery. Protect secrets and private notes.

## Sync and collaboration

- Changes should appear in an open note without closing it. Aim for 1–3 seconds when free-tier capacity permits; current timing is acceptable if open-note updates work and faster delivery is too difficult.
- Simultaneous changes, including edits at the same position, should merge automatically with deterministic ordering. Offline changes merge with recoverable history. Participant cursors show names and colors.
- Replace Review edits with simple recovery only when automatic merging is demonstrably reliable. Preserve every unresolved edit; never silently discard it.
- Offline retry with clear warning. Periodic Android background sync with battery safeguards; exact timing depends on OS. Linux sync while running/minimized; closing window quits app, except allowed reminder service.
- Remove LAN sync entirely only after reliable cloud parity and recovery of pending LAN data. No new LAN discovery or routing features.

## Workspaces and agent access

- Many practical workspaces under one Google identity; each has separate notes, folders, search, Trash and optional chat. Switch on Android, Linux, iPhone web and subsequent supported platforms.
- Personal workspace inaccessible to agents. Manually copy notes into shared workspaces; no cross-workspace move or automated copy requirement yet.
- Any compatible external agent can use a common authenticated interface, CLI plus MCP; cloud access when laptop is off.
- Individual revocable scoped identities. Read/create/edit authorized notes; owner approval for permanent deletion. Record agent, timestamp and change history. No direct database access.
- Notes and chat first; task management later. Channels with optional threads, DMs, mentions, note links and attachments with safe limits. Respond when mentioned or explicitly requested. Only connected agents respond; queue offline messages until reconnect. Do not automatically launch agents.
- Note-change alerts only for chosen agent workspaces or important events.

## Editor

- Ctrl+Up/Down paragraph navigation; last-line Down must not wrap upward; Linux vertical mouse drag selection and scrolling work. Preserve cursor, selection and focus during formatting. Regression-test basic Ctrl+A/C/X, paste, Shift-selection, arrows, touch and keyboard behaviors.
- Inline code monospace; code blocks with language labels, Copy, highlighting and word-wrap controls. Keep existing rich-text format unless safe combination of quote/list/code is proven.
- Undo/Redo includes checklist toggles and moves between completed/unfinished sections; top-bar buttons with optional toolbar duplicates.
- Synchronized bounded history: target 30 versions or 30 days subject to storage; exact retention policy to be specified. Save failure keeps a recoverable draft and warns user.
- Built-in/custom templates, heading outline, Markdown typing shortcuts, Find and Replace on Android/Linux, unfinished checklist filter, optional distraction-free mode. No editor slash commands.
- Tables later after stable editor. Rich link preview on request plus setting for automatic preview, subject to privacy/network review.
- Internal note links via search and backlinks in Note details. Details include created/edited dates, folder, word/character counts, size and backlinks. Image Copy and Save actions.

## Library, desktop and appearance

- Nested collapsible folders; deletion asks whether to move contents or delete them. Folder dropdown shows direct notes; subfolders navigable. One global sort.
- Automatic Trash deletion after 30 days, with fresh 30-day grace for existing Trash. Exact release placement open; implement only after safe recovery and sync checks.
- Desktop sidebar reorder/hide/resize/move sides. Arrow keys move note highlight, Enter opens. F11/button fullscreen preserves layout; app-themed window controls retain normal behavior. Ctrl+R sync when not conflicting with editor shortcuts.
- Android toolbar long press to reorder/hide/reset. Quick access to theme, layout, sync status, editor settings and search. Responsive usable interface.
- True AMOLED default, charcoal, light and follow-system option; per-device primary/secondary accent and device colors where supported. Appearance device-specific.
- Library/editor solid colors, gradients and imported backgrounds; default editor background per device and optional per-note overrides. Define storage and sync semantics at design time.
- Android haptics with disable option; small smooth motions honor reduced motion. Selective Material 3 Expressive components only when helpful. Dither only inexpensive and toggleable. Third-party UI only with clear benefit and compatible license.
- Separate short first-install motion intro if feasible, normal startup fast; motion asset created separately. What's new and in-app changelog. English only.

## Platforms and Android

- iPhone browser online-first with rich editing and photo attachments, then offline after stable. Home Screen install and notifications if easy and zero additional cost.
- Windows next native platform, then iPad responsive layout, then Android tablet if time. Avoid parallel independent editors unless technical evidence requires it.
- Android ARM64, ARM32 and x86_64 if dependencies support; separate APKs and updater selects ABI. Keep Android 7 minimum if safe and compatible.
- Four widgets: quick capture, interactive checklist, pinned notes and single note. Reminders and agent activity later. Respect privacy, safe writes and platform constraints.
- Launcher new note/checklist/search shortcuts, themed icon, share text/images to new or existing notes, selected-text capture, pull to sync. Test predictive back and modernize native API use when justified.

## Reminders and backups

- One-time, hourly, daily, weekly and custom interval/weekday reminders. Enable devices individually and choose devices per reminder. Done dismisses everywhere; Snooze targets current device or all. Tap opens associated note.
- Lightweight Linux reminder service while app closed. Push only if safe and zero additional cost; platform permission and fallback handling. Calendar export later.
- Readable JSON backup with optional password encryption; scheduled daily/weekly to user-selected folder; retain last seven verified backups. Optional non-secret settings, never tokens or device secrets. Restore retains previous verified snapshot until replacement is verified.
- Recovery key deferred until backup improvements stable. No Google Keep or encrypted legacy Notebook import.
- Markdown ZIP with attachments; plain-text export/share; warn unsupported Markdown formatting and preserve faithful JSON option.
- Safe local/cloud removal of unreferenced images only after accounting for revisions, pending sync and other devices. Optional compression with original available.

## Development and acceptance

- Codex may lead; Claude leads difficult work with Codex workers where useful; Antigravity/Gemini for implementation/review where measurable; OpenCode additional bounded workers. Native harnesses, standard speed, minimal context, no unnecessary plugins. No T3 Code.
- Separate branches/worktrees, explicit path ownership and durable handovers. Laptop integration/physical testing, other machine and eligible cloud environments for independent tasks. Actual account access checked at kickoff; never put credentials or usage details in Git.
- Run Flutter and Worker checks, optional package builds and appropriate real-device tests. Reproduce basic defects before fixing, add regressions, record skips honestly. Ask owner for manual tests only after autonomous work ends, not mid-goal; unattended tasks report what remains.
- Keep approved requirements and changed behavior documented. Future ideas remain possible; the roadmap is not frozen forever. Existing security, signing, merge and deployment approval rules remain in force.
