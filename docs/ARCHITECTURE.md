# Architecture

How Notes works and how to change it safely. Everything here is derived from
the code in this checkout; where this file and another document disagree, the
code wins. Requirements live in [PRODUCT.md](PRODUCT.md), the reasons behind
the stack in [DECISIONS.md](DECISIONS.md), update trust in
[UPDATES.md](UPDATES.md), release steps in [RELEASE.md](RELEASE.md).

Notes is an offline-first Flutter app for Android (arm64) and Linux (x64). It
stores notes in one encrypted SQLite file and syncs directly over LAN between
up to five of the owner's devices. Optional private cloud sync uses one
configured Google account and a Cloudflare Worker/Neon server. Cloud sync is
off until sign-in and explicit upload; the server stores readable note JSON,
so it is not end-to-end encrypted. See [section 6.9](#69-cloud-sync) and
[CLOUD_SYNC.md](CLOUD_SYNC.md).

## 1. Overview and layering

### 1.1 Source layout

| Directory | Contents | May import |
|---|---|---|
| `lib/core/` | ids, hybrid logical clock, version vectors, app version | Dart SDK, `crypto` only |
| `lib/data/` | SQLite wrapper, migrations, models, `NoteRepository`, `AppSettings` | `core`, `doc`, `sqlite3`, `package:flutter/foundation.dart` (for `ChangeNotifier`) |
| `lib/doc/` | Quill Delta helpers: digest, checklist projection, Markdown, bounded line merge | `dart_quill_delta`, `markdown` |
| `lib/importer/` | legacy Notebook import, Markdown import, Notes JSON export and restore | `core`, `data`, `doc`, `sync/merge.dart` |
| `lib/sync/` | pairing, secure channel, session protocol, merge, TCP/UDP service | `core`, `data`, `doc`, `cryptography` |
| `lib/sync/cloud/` | cloud API, revisioned pull/push, blobs, upload/join and cloud service | `core`, `data`, `doc`, `sync/merge.dart`, `platform/cloud_login.dart`, `dart:io`, `flutter_secure_storage`, `foundation.dart` |
| `lib/update/` | GitHub release check, manifest verification, download, installers | `core`, `data/app_settings.dart` |
| `lib/platform/` | `bootstrap()` and `AppServices`; native save-file channel | everything below `ui` |
| `lib/ui/` | screens and widgets | everything; Material only through `lib/ui/material.dart` |
| `lib/app.dart`, `lib/main.dart` | app shell, entry point | |

Dependency rules (a change that breaks one needs a reason):

- `core`, `doc`, `data`, `importer`, `sync` contain no Flutter widgets. They
  use only `foundation.dart` for `ChangeNotifier` and `defaultTargetPlatform`;
  `sync/cloud` also uses platform secure storage and the HTTP client.
- Nothing below `ui` imports `ui`. `data` does not import `sync`, `importer` or
  `update`. `sync` and `importer` reach the database only through
  `NoteRepository`, `PeerStore` and `AppDatabase.transaction`.
- `lib/update/` and `lib/sync/` touch the network. Cloud requests are isolated
  behind `CloudApi`; update bookkeeping uses `UpdateStateStore`, which is
  backed by `AppSettings.writeSilently`.
- `lib/ui/material.dart` is the single Material import (D3 in DECISIONS.md).
  Every UI file imports it, never `package:flutter/material.dart`.
- State management is `ChangeNotifier`/`ValueNotifier`/`ListenableBuilder` plus
  constructor injection (D10). `AppScope` (an `InheritedWidget` in
  `lib/app.dart`) hands `AppServices` to the widget tree.

### 1.2 Startup

```
lib/main.dart  main()
  WidgetsFlutterBinding.ensureInitialized()
  runApp(Launcher(start: ...))                 lib/ui/splash.dart
      SplashScreen shown immediately (glyph + "Notes" on black)
      start():
        bootstrap()                            lib/platform/bootstrap.dart
          -> NotesApp(services)                lib/app.dart
        on any Object error -> StartupErrorApp(error)   lib/ui/startup_error.dart
  Launcher cross-fades (220 ms, 0 with reduce-motion) from splash to the result
```

`bootstrap({dataDir, keyStore})` in order:

1. Resolve the data directory (section 3.2) and create it.
2. Pick a `KeyStore`: `SecureKeyStore` normally, `FileKeyStore(<dir>/dev.key)`
   when `NOTES_DATA_DIR` is set.
3. Read the key. No key and `notes.db` exists: throw
   `DatabaseKeyMissingException`. No key and no file: generate 32 random bytes,
   store them, read them back, and fail with `StateError` if the keystore did
   not keep them.
4. `AppDatabase.open(path, key: key)`: key check, pragmas, backup, migrations.
5. Build `NoteRepository`, `AppSettings`. If `db.createdNow`, write
   `onboarding = pending` (section 2.7).
6. `DeviceIdentity.loadOrCreate(db)`, then `SyncService` (port 47380; port 0
   for a dev instance). A settings listener keeps `sync.deviceName` current.
7. Wire the Linux installer's `onPrepareQuit`, `onInstallAborted` and `onQuit`
   callbacks to `AppServices`: prepare uses its `EditorSaveBarrier`, abort
   releases it if helper setup fails, and quit closes services after the helper
   starts. `createPlatformInstaller` returns an Android or Linux installer,
   null elsewhere. If non-null, build `UpdateController.forApp`.
8. Resolve the cloud endpoint (section 6.9), select secure or development
   session storage, construct `CloudService` when an endpoint is available, and
   restore its local session state.
9. Return `AppServices(db, notes, settings, dir, sync:, cloud:, updates:)`.

`AppServices.inMemory()` is the test constructor: in-memory database, no LAN or
cloud sync, no updater. `AppServices.close()` disposes updates, cloud, sync,
settings and database.
Before the Linux helper is copied or started, `EditorSaveBarrier` freezes all
live editor sessions and waits for their pending writes and disposed-editor
save handoffs to confirm persistence. A failed or timed-out save releases the
freeze and leaves Notes open for Retry. After the helper starts,
`quitForUpdate()` disposes sync, closes the database and exits immediately.

`NotesApp` (`lib/app.dart`):

- Builds `MaterialApp` inside `AppScope`, rebuilding on `AppSettings` changes:
  `buildTheme(settings)`, theme animation duration from `AppMotion`, localisation
  delegate for Quill (its find dialog throws without it), and a `MediaQuery`
  wrapper that multiplies the platform text scaler by `settings.textScale`.
- `initState`: completes onboarding if the database already holds user data;
  schedules the update check after the first frame; starts sync
  (`sync.start()` then `requestAutoSync(2 s)`); listens to
  `notes.changes` to request an auto sync 20 s after local edits settle.
- On `AppLifecycleState.resumed`: `sync.start()` (idempotent) then
  `requestAutoSync(1 s)`.
- `CloudService.start()` is also called at startup and resume. Android stops
  cloud polling when the app is paused; Linux keeps it while the window is open
  or minimized and stops when the process quits.
- Home is `_Root`: `OnboardingScreen` when `settings.onboardingPending`, else
  `LibraryScreen`.

`Launcher` (`lib/ui/splash.dart`) owns only the splash-to-app switch; it holds
no services. Android has a matching native launch screen
(`android/app/src/main/res/drawable*/launch_background.xml`, `values*/styles.xml`;
checked by `test/android/splash_resources_test.dart`).

## 2. Data model

### 2.1 Tables (`lib/data/migrations.dart`)

Schema version 4 (`schemaVersion == migrations.length`). `PRAGMA user_version`
holds the applied version.

| Table | Purpose | Key columns |
|---|---|---|
| `local_meta` | device-local state, never synced | `device_id`, `hlc_last`, `seq`, `identity_private` (X25519 private key), LAN/cloud cursors and cloud state |
| `settings` | per-device preferences and small UI/updater state, never synced | `key`, `value` |
| `folders` | flat folders | `id`, `name` + `name_hlc`, `deleted` + `deleted_hlc`, `local_seq` |
| `notes` | every note, including deleted-forever tombstones | see 2.2 |
| `notes_fts` | FTS5 index over `title`, `plain_text` (external-content, triggers keep it current) | `unicode61 remove_diacritics 2`, prefix 2-4 |
| `attachments` | image bytes by SHA-256; `data` is NULL until the bytes arrive | `hash`, `mime`, `size`, `data` |
| `note_attachments` | which note references which hash; derived from bodies | `(note_id, hash)` |
| `import_batches`, `import_records` | legacy-import audit trail and rollback data | section 5 |
| `peers` | paired devices (v2) | `id`, `public_key`, `endpoints` (JSON), `sent_cursor`, `recv_cursor`, `last_error` |
| `quarantine` | rows received from a peer that could not be applied (v3) | `peer_id`, `kind`, `reason`, `raw` |
| `cloud_notes` | cloud revision, digest and three-way merge base per record (v4) | `(kind,id)`, `rev`, `digest`, `base_title`, `base_body`, `base_vv`, `base_hlc` |

### 2.2 The `notes` row

| Column group | Meaning |
|---|---|
| `id` | UUID text. Random v4 for new notes; `derivedId(...)` (SHA-256 based, version nibble 8) for conflict copies and imported/merged folders |
| `pk` | integer rowid used by the FTS index (survives `VACUUM`) |
| `title`, `body` | `body` is a Quill Delta op array as JSON text (section 4) |
| `plain_text`, `preview`, `tasks_total`, `tasks_done` | derived from `body` by `digestBody` on every write; never edited directly |
| `created_at`, `updated_at` | epoch ms |
| `content_hlc`, `content_vv` | clock and version vector of title+body (and of deletion) |
| `purged` | 1 = deleted forever (tombstone, empty title and body) |
| `pinned`/`pinned_hlc`, `archived`/`archived_hlc`, `folder_id`/`folder_hlc`, `trashed_at`/`trashed_hlc`, `conflict_of`/`conflict_hlc` | independent last-writer-wins registers, each with its own HLC |
| `local_seq` | value of the device change counter at the last write; the sync queue |

`NoteRecord` (`lib/data/models.dart`) is the full row; `NoteSummary` and `Note`
are the UI views. `NoteRecord.toJson` is the wire and export format.

### 2.3 Identity, clocks, versions (`lib/core/`)

- Device id: 16 hex characters (`newDeviceId`), stored in `local_meta`. Stable
  for the life of the database.
- `Hlc`: `<12 hex millis><4 hex counter>-<node>`. String order equals
  chronological order. `HlcClock.now()` is strictly increasing; `observe()`
  folds in remote stamps. The last stamp is persisted in `local_meta.hlc_last`
  when a transaction commits. The clock is never rewound on rollback, so a
  stamp is never reused.
- `VersionVector`: map node to write count; `compare` returns `equal`,
  `dominates`, `dominated`, `concurrent`. Canonical JSON (sorted keys) is what is
  stored, compared and hashed.
- Local change counter: `AppDatabase.nextSeq()` gives each written row a
  `local_seq`; `local_meta.seq` is persisted at commit and rolled back with the
  transaction.

### 2.4 Lifecycle states

| State | Representation | Visible in |
|---|---|---|
| Active | `purged=0, trashed_at NULL, archived=0` | library |
| Pinned | `pinned=1` (sorted first in the active scope) | library |
| Archived | `archived=1` | Archive scope |
| Trash | `trashed_at` set | Trash scope; editor opens read-only |
| Conflict copy | `conflict_of` set | Conflicts scope until "kept" (`keepConflictCopy` clears it) |
| Deleted forever | `purged=1`, title and body emptied, `content_vv` incremented | nowhere; the tombstone syncs the deletion |

`NoteRepository.normalise` applies to every write (edit, merge, import):

- a tombstone carries no content;
- content whose `content_hlc` is newer than `trashed_hlc` clears `trashed_at`
  (editing a trashed note brings it back).

`NoteScope` is `active`, `archived`, `trash`, `conflicts`. Folders are flat.
`deleteFolder` marks the folder deleted; its notes stay and show as unfiled
(their `folder_id` is not rewritten). `createFolder` reuses an existing live
folder with the same name (case-insensitive) and otherwise gives it
`derivedId('folder', [lowercased name])`, so two devices creating "Work" get the
same id; a name whose derived id was used before gets a random id.

### 2.5 Transactions and `NoteRepository`

`AppDatabase.transaction(body)` (`BEGIN IMMEDIATE`): nested calls join the outer
one; an exception rolls back everything, including the sequence counter;
listeners on `db.changes` fire once after a commit that called `markChanged()`.
SQLite is opened with WAL, `synchronous=NORMAL`, foreign keys on, 5 s busy
timeout. Calls are synchronous on the UI isolate (D4).

Rules, enforced by convention and by review:

- Every multi-row write runs in one `db.transaction`.
- All note and folder mutations go through `NoteRepository`
  (`lib/data/note_repository.dart`). Only it stamps `content_hlc`, version
  vectors, per-field HLCs and `local_seq`, recomputes the derived columns and
  maintains `note_attachments`. SQL that updates `notes` or `folders` elsewhere
  would leave other devices without the change or break the index.
- `writeRecord` / `writeFolderRecord` are the single choke points for row
  writes. They are "low level": the caller supplies clocks and must be inside a
  transaction. Used by the repository, `RemoteApplier` (sync, restore) and the
  importer.
- `saveContent(id, title, body, base)` is the editor write path. If the stored
  version vector differs from `base` (sync wrote underneath), the stored
  version is kept as a deterministic conflict copy and the editor's content
  becomes the note (`SaveOutcome.savedWithConflictCopy`).
- `repo.changes` (from the database) drives library reloads and auto sync.

### 2.6 Settings (`lib/data/app_settings.dart`)

`AppSettings` is a `ChangeNotifier` over the `settings` table, loaded fully at
construction. Typed getters have defaults and clamp numeric ranges (text scale
0.85-1.4, editor font 12-28, line height 1.1-2.0, preview lines 0-10). Enums
(`AppTheme`, `AppFont`, `LibraryLayout`, `StartupView`, `NoteSort`,
`AnimationLevel`) are stored by `name`; an unknown stored value falls back to
the default, so removing an enum value is safe only if the fallback is
acceptable. `StartupView` defaults to `unfiled`, including when its key is
missing on an upgraded install; `all` opens All notes and `last` restores the
view in `library.folder` (a folder id, `unfiled`, or absent for All). The
setting is per-device and does not sync.

| Mechanism | Use |
|---|---|
| typed setter (`theme = ...`) | persists and notifies listeners (rebuilds the whole `MaterialApp`) |
| `read(key)` / `write(key, value)` | small UI state such as the selected folder; notifies |
| `writeSilently(key, value)` | bookkeeping nobody renders (update timestamps, ETag, replay mark); does not notify |

Settings never sync. Keys used by code: appearance, editor and `startupView`
keys above, `library.folder` (the most recently selected active folder/view),
`toolbar` (JSON list of `ToolbarItem` names), `deviceName`, `onboarding`
(`pending` or `done`), `autoCheckUpdates`, and the `update.*` keys in
`UpdateKeys`.

### 2.7 First-use state

`AppDatabase.createdNow` is true only when `open` found schema version 0. Only
then does `bootstrap` write `onboarding = pending`. A missing key means "do not
show", so every upgraded install skips onboarding. `NotesApp.initState` also
completes onboarding when `AppSettings.hasUserData` (any row in `notes`,
`folders`, `attachments`, `import_batches`, `peers`). Onboarding never creates
sample notes; that would bump the change counter and sync to paired devices.

### 2.8 Migrations

- `migrations` is an ordered list of statement lists; `migrations[i]` upgrades
  version `i` to `i+1`. Append only; a released entry is never edited.
- `AppDatabase.open` runs each missing step in its own `BEGIN IMMEDIATE ...
  COMMIT` and sets `user_version` inside it. A failing step rolls back.
- Before migrating an existing database on disk it writes
  `<db>.pre-v<target>.bak` with `VACUUM INTO` (same encryption), replacing an
  earlier backup of the same name.
- A database newer than the app throws `DatabaseTooNewException`; the app shows
  an error screen and changes nothing.
- Migration 4 adds cloud merge bookkeeping. A 1.2.0 build refuses a database
  after a 1.3.0 build has migrated it; LAN interoperability between 1.2.0
  databases remains unchanged.
- Every migration needs a test that creates a database at the previous version
  and upgrades it. The pattern is `AppDatabase.open(path, schema:
  migrations.sublist(0, n))`, then reopen with the full list: see
  `test/e2e/persistence_test.dart` (v1 to current, notes kept, `.pre-v` backup
  written) and `test/sync/peers_test.dart` (v1 to current with peers).
  `test/data/app_database_test.dart` tests the runner itself with a synthetic
  next version. There is no dedicated v2 to v3 test.

## 3. Storage and encryption at rest

### 3.1 Library and key

- `sqlite3` 3.9 with the SQLite3 Multiple Ciphers build, selected by
  `hooks.user_defines.sqlite3.source: sqlite3mc` in `pubspec.yaml` (D4).
  Cipher is ChaCha20-Poly1305.
- `AppDatabase.open` runs `PRAGMA key = 'raw:<64 hex>'` with a 32-byte key,
  then reads `user_version` and `sqlite_master`. A wrong key or non-database
  file throws `DatabaseUnreadableException` before any pragma or write touches
  the file.
- Image attachments are blobs in the same database, so they are encrypted too
  (D9).
- Exported Notes JSON (`lib/importer/notes_export.dart`) is not encrypted.

### 3.2 Where things live

| Item | Android | Linux |
|---|---|---|
| Data directory | `getApplicationSupportDirectory()` (app-private) | `getApplicationSupportDirectory()`: `$XDG_DATA_HOME/com.mmoptibuilds.notes`, normally `~/.local/share/com.mmoptibuilds.notes/` |
| Database | `<dir>/notes.db` (+ `-wal`, `-shm`, `notes.db.pre-vN.bak`) | same |
| 32-byte key | Android Keystore through `flutter_secure_storage` (entry `notes.db.key.v1`) | Secret Service / GNOME Keyring through `flutter_secure_storage`, same entry name |
| Program files | APK | `~/.local/opt/notes`, launcher `~/.local/bin/notes` (installer) |
| Updater state | `<updates dir>` from the Kotlin plugin | `${XDG_STATE_HOME:-~/.local/state}/com.mmoptibuilds.notes/updater/` |

`NOTES_DATA_DIR=<dir>` overrides the data directory on any platform. A set
variable also: stores the key in `<dir>/dev.key` (plain file, no protection),
binds the sync port to an ephemeral port instead of 47380, and disables
automatic update checks. It exists for second instances and tests. Never point
it at real data from automation.

### 3.3 Failure behaviour

`StartupErrorApp` replaces the app without modifying the database. Missing key,
wrong key and newer schema show “Your notes are locked”, “Your notes could not
be opened” and “This version of Notes is too old”; other startup failures show
“Notes could not start” plus the error. Losing the key requires recovery from a
paired device or an exported JSON file (D5).

### 3.4 Android backup

`android:allowBackup="false"`, plus `fullBackupContent` (`backup_rules.xml`) and
`dataExtractionRules` (`data_extraction_rules.xml`) excluding every domain for
cloud backup and device transfer. A restored database without its Keystore key
could not be opened anyway. No `cross-platform-transfer` section is declared
(D17). `test/android/backup_config_test.dart` pins this.

## 4. Document format (`lib/doc/`)

### 4.1 Stored form

`notes.body` is the JSON array of Quill Delta ops (`bodyFromDelta` =
`jsonEncode(delta.toJson())`). `decodeOps` also accepts `{"ops": [...]}`. The
empty document is `emptyBodyJson` (`[{"insert":"\n"}]`). `saveContent` rejects a
body that is not a Delta before touching the database. Images are embeds whose
source is `att:<sha256>` (`attachmentScheme`), resolved through the
`attachments` table.

### 4.2 Digest (`delta_text.dart`)

`digestBody(body)` derives, on every write, `plainText` (one line per document
line, indexed for search), `preview` (up to 10 lines / 360 chars; checked tasks
omitted; open tasks prefixed with a box, bullets and numbers rendered),
`tasksTotal`, `tasksDone` and `imageSources`. The library reads only these
columns and never decodes bodies for lists.

### 4.3 Checklist projection (`checklist_projection.dart`)

The stored document keeps every checklist line where the user put it. The
editor shows a *visible* document without checked lines; the checked lines are
held as `CompletedLine`s with anchors (offsets in the visible document at the
start of a visible line, or the document end).

- `ChecklistProjection.split(canonical)` returns `(visible, projection)`.
- `transformBy` moves anchors as the visible document is edited.
- `merge(visible)` re-inserts completed lines at their anchors and yields the
  canonical document that is saved. Invariant: `merge(split(d).visible) == d`
  for any document `d` (property-tested).
- When every line is checked, a synthetic empty visible line is invented; it is
  not stored.
- Opening a note writes nothing; only an edit saves, and the save is the merged
  canonical document, so formatting of hidden lines survives.
- Setting `completedSection = false` loads the canonical document directly.
- Known cost: checking or restoring an item clears the editor's undo history.

### 4.4 Markdown (`markdown.dart`)

Hand-written on top of `package:markdown` (not `markdown_quill`). One canonical
output form so export, import, export is stable.

- `deltaToMarkdown(body)`: `**bold**`, `*italic*`, `~~strike~~`, code spans,
  links, headings, quotes, code blocks, lists nested by four spaces,
  `- [ ]`/`- [x]` checklists, images as `![](source)`. Underline, colour, size and
  alignment have no Markdown form and are dropped (text kept). Unknown embeds are
  written as `[type]`. Throws `FormatException` only if the input is not a Delta.
- `markdownToDelta(text)`: the inverse; the result always ends in a newline.
- Export: the editor's "Copy as Markdown" (title as a `#` heading).
- Import: Settings → Import and export → "Import Markdown files"
  (`lib/importer/markdown_import.dart`): one note per file, all files in one
  transaction; a leading `# Heading` becomes the title, otherwise the file name.

## 5. Importers (`lib/importer/`)

### 5.1 Legacy Notebook backup (`legacy_backup.dart`)

Input: the unencrypted JSON export of the old app. An encrypted export
(`encrypted: true`, or `salt`/`iv`/`ciphertext` without `notes`) is refused with
a readable message. `LegacyBackupFormatException` means "not a backup": nothing
is written.

| Aspect | Behaviour |
|---|---|
| Versioning | `legacyKnownVersion = 11`. A higher `version` imports with a warning; fields the importer does not know stay verbatim in `import_records.raw`. Missing or `< 1` version only warns |
| Scope | tables `notes`, `tags`, `noteTags`, `deletedNotes`; other non-empty tables are counted in `outOfScopeTables` and ignored |
| Fields with no home | colour, tags, reminder, lock flag, image path, preview text: counted in `unsupportedFields`, kept in `raw`, not shown |
| Ids | a source note keeps its legacy id; folders get `derivedId` from the name |
| Version vector | `{"legacy:<16 hex of sha256(title \0 body)>": 1}`; HLCs from legacy timestamps (node `legacy`), so two devices importing the same file produce identical rows that sync as equal |
| States | deleted source notes become trashed notes; archived stay archived |
| Plain text | non-Delta content is converted to a body and counted |
| Report | `ImportReport`: counts only, never titles, text or image paths. Stored in `import_batches.report` |

Per source note the action is one of `created`, `unchanged`, `updated`,
`skipped_older`, `conflict_copy`, `restored`, `skipped_deleted`:

- no local row: `created`;
- local version equal to or dominating the source: `unchanged` (this is what
  makes re-import idempotent);
- local still only has `legacy:*` versions: `updated` if the source is newer,
  else `skipped_older`;
- local was edited in the new app: `unchanged` if this exact source was already
  recorded or its conflict copy exists, otherwise `conflict_copy` (local edits
  are never overwritten);
- local is a tombstone: `restored` only if the batch that last wrote it was
  rolled back, otherwise `skipped_deleted`.

Atomicity: `import()` runs one transaction that inserts the batch row, every
record and the report; an exception (including a test hook) rolls back
everything. If a snapshot path is given and the database is on disk, a
`VACUUM INTO` copy is written first. `inspect()` is the dry run (same logic,
`write: false`).

Rollback: `rollback(batchId)` (one transaction, idempotent) undoes only notes
still at exactly the version the import wrote (`written_vv`). `created`,
`restored` and conflict-copy notes are purged; `updated` notes are reverted to
`previous` with a fresh clock; edited notes are kept and counted
(`keptEdited`, `copiesKept`). Folders the batch created are deleted if empty.
`attachImages` stores image files the backup could not carry and fills missing
attachment placeholders.

### 5.2 Notes export and restore

- `exportAll(repo)` (`notes_export.dart`): `format: "notes-export"`,
  `version: 1`; all note rows (including tombstones), folders, and stored
  attachment bytes as base64. Unencrypted. `parseExport` rejects other formats
  with specific messages (including "this is a Notebook backup") and versions
  above `exportVersion`.
- `NotesExportRestorer` (`notes_restore.dart`): `inspect` is a read-only preview;
  `apply` runs in one transaction through `RemoteApplier`, so restore follows
  exactly the sync merge rules (newer local content is never overwritten, a
  tombstone cannot resurrect a newer local purge, concurrent edits produce
  deterministic conflict copies). Folders first, then notes, then attachment
  bytes; a hash whose local bytes differ aborts everything.
- `writeExportAtomically` (`atomic_export.dart`) writes via a flushed temp file
  and rename, so a failed export leaves the previous file intact.
- Android saves exports through the system document picker
  (`lib/platform/save_file.dart` and `MainActivity.kt`, method channel
  `com.mmoptibuilds.notes/save`); Linux uses `file_selector`.
- Every manual JSON export attempt first asks the user to confirm that the
  backup is unencrypted. Canceling or dismissing the warning does not build the
  JSON or open a destination picker; Continue starts the existing export flow.

## 6. Sync (`lib/sync/`)

### 6.1 Model

Records, not operations (D13). Each side sends note and folder rows whose
`local_seq` is above the peer's confirmed cursor; the receiver merges whole rows
with `RemoteApplier`, which is idempotent and order-independent. LAN sync has no
shared merge base, so concurrent content edits keep both versions as conflict
copies. Cloud sync can use a stored base for a bounded three-way line merge
(section 6.9).

### 6.2 Merge rules (`merge.dart`)

`mergeNotes(a, b)` is symmetric:

| Situation | Result |
|---|---|
| one version vector dominates | it wins |
| concurrent edits | later `content_hlc` wins; the other becomes a conflict copy |
| equal vectors, different content (a bug or damaged peer) | treated as concurrent; both kept |
| edit vs concurrent delete-forever | the edit wins; nothing is lost (D16) |
| both purged / one purged and the other not concurrent as above | tombstone follows the vector rules |
| pinned, archived, folder, trashed, conflict flag | independent LWW registers by their own HLC (ties broken by value text) |
| `created_at` | minimum |
| resulting `content_vv` | pointwise maximum |

The result goes through `normalise` (newer content un-trashes). Folders merge
name and deleted flag as separate LWW registers.

Conflict copies: `conflictCopyOf(loser)` derives the copy's id from
`derivedId('conflict', [loser.id, loser.contentVv])`, with
`content_vv = {"conflict:<id8>": 1}` and `conflict_of = loser.id`. Every device
that sees the same conflict builds the identical row, and
`insertConflictCopyIfAbsent` never creates it twice (even if the copy was later
deleted). The sender emits rows in `local_seq` order and the receiver applies a
whole batch in one transaction, so a conflict copy and the note that resolved it
are never separated (D13).

Clock guard: `RemoteApplier` throws `ClockSkewException` if any received stamp is
more than 2 days ahead of local time; the batch is not applied.

Deletions: trash and archive are LWW registers (restoring later wins); purge is
a content write leaving a tombstone that syncs.

### 6.3 Pairing (`pairing.dart`, `peers.dart`)

1. Device A calls `SyncService.beginPairing()`: a `PairingHost` creates an offer
   (8-byte id, 32-byte secret, 5-minute lifetime). The QR text is
   `notes-pair:1:` + base64url(JSON of device id, name, offer id, secret, expiry,
   up to 12 `host:port` endpoints, LAN first).
2. Device B scans it (Android camera via `mobile_scanner`; Linux has no scanner
   and uses paste) and calls `pairWith(code)`. It dials the endpoints and runs
   the pairing-mode handshake (6.5), which mixes the offer secret into the
   keys.
3. The offer is single use: `PairingHost.consume()` is an atomic claim, the first
   handshake to prove the secret wins; the offer is withdrawn after 5 lookups
   (`maxAttempts`) and when expired.
4. Inside the channel `completePairing` exchanges `peer` messages (id, name,
   X25519 public key, endpoints). Each side validates the claim against the
   channel's proven id, then sends `accept` or `reject`. A peer is stored only if
   both accepted. Refused: more than the device limit, or a known id with a
   different key (remove the old entry first).
5. `PeerStore.add` writes the `peers` row with up to 6 endpoints.

Limit: `maxDevices = 5` includes this device, so at most 4 peers
(`PairingLimitException`). PRODUCT.md's "up to five paired devices" means five
devices in total.

Identity: each device has one long-term X25519 key pair
(`DeviceIdentity`); the private half lives in the encrypted database
(`local_meta.identity_private`).

### 6.4 Transport and discovery (`sync_service.dart`, `tcp_transport.dart`)

| Item | Value |
|---|---|
| Sync | TCP 47380 (`defaultSyncPort`), bound on `0.0.0.0` IPv4 only. If the port is taken the OS picks another and that port is what peers learn |
| Discovery | UDP 47381 (`discoveryPort`), IPv4 broadcast only |
| Framing | 4-byte big-endian length, then the frame; length checked against `maxMessageBytes + 1024` before allocation; reads pause when 2 frames are queued (TCP back-pressure) |
| Inbound limits | 6 concurrent unauthenticated handshakes, 2 per address, 3 sessions; handshake timeout 6 s |
| Dial | 3 s connect, 10 s handshake; endpoints tried in order, then discovery |
| Back-off after a failed dial | 20 s, 60 s, 180 s, 600 s, 900 s |

Discovery: a device that cannot reach any stored endpoint broadcasts
`"NTSD1" + tag` to `255.255.255.255` and to each local `/24` broadcast address
(`a.b.c.255`), where `tag` = first 8 bytes of
`sha256("notes-discovery-v2" + deviceId + ":" + utcDay)` (rotates daily,
yesterday and tomorrow also accepted). The target replies `"NTSR1" + tag + port`
unicast. Waits 1.5 s. Best effort: failure is silent.

A successful session records the endpoint that worked in `peers.endpoints`
(most recent first). Tailscale addresses (100.64.0.0/10) are ordinary endpoints
and are labelled as such by `describeEndpoint`.

### 6.5 Secure channel (`secure_channel.dart`)

Noise-style handshake over any `FrameTransport` (TCP in production,
`test/support/memory_transport.dart` in tests). Version byte
`secureChannelVersion = 1`, magic `NTS1`; an unknown version fails with
`HandshakeException(peerVersion:)`.

| Primitive | Use |
|---|---|
| X25519 (`cryptography`) | ephemeral and long-term key agreement |
| HKDF-SHA256, info `notes-sync v1 keys` | 64 bytes: one key per direction |
| ChaCha20-Poly1305 AEAD | every frame, 16-byte tag, handshake transcript hash as AAD |
| SHA-256 (`crypto`) | transcript binding, discovery tags, content hashes |

- Session mode (paired devices): input keying material is the ephemeral-ephemeral
  DH plus three DHs with the stored static keys (es, se, ss). Only the holder of
  the peer's stored private key completes it, so the peer id is proven.
- Pairing mode: ephemeral-ephemeral DH plus the one-time offer secret; the peer
  id is only as trustworthy as that secret and is confirmed inside the channel.
- Replay protection: the AEAD nonce is the frame counter (counter 0 is the
  handshake confirmation, data starts at 1), one counter per direction. A dropped,
  duplicated, reordered or replayed frame fails authentication; the channel is
  closed (`ChannelIntegrityException`).
- `MessageStream` (`protocol.dart`) sends JSON messages, fragmenting anything over
  700 KiB into 512 KiB pieces and reassembling up to 64 MiB.
- Limits (`SyncLimits`): 500,000 rows and 512 MiB of data per session, 64 MiB per
  attachment, 512 MiB attachment bytes per session, 500 hashes per `need`.

### 6.6 Session protocol (`sync_session.dart`)

Both sides run the same code over an established session channel:

1. `hello`: `proto: 1`, device id, name, `schema` (our schema version), `from`
   (highest of the peer's rows we have: our `recv_cursor`), `max` (our current
   sequence). The id must match the paired peer.
2. Send folders then notes with `local_seq > theirFrom` in `rows` batches, then
   `done` (count, `upTo`, `reset`). If their cursor exceeds our sequence we were
   restored from an older copy: send everything and flag `reset`, and the
   receiver sets (not raises) its cursor.
3. Receive until `done`; check the count; then apply everything in one
   transaction, which also advances `recv_cursor`. Unparseable rows go to
   `quarantine` (bounded: 500 rows, 8 MiB; if a batch would exceed the bound the
   transaction fails and the sender keeps the batch). Earlier quarantined rows
   are retried first (at most 100 rows / 8 MiB per session) in case this build
   can now parse them.
4. `applied` (`upTo`), then advance `sent_cursor` (never above our snapshot).
5. Images: `need` lists hashes our notes reference without bytes; the peer
   answers with `blob` chunks (192 KiB) or `blobmissing`; bytes are stored only
   after the SHA-256 matches.
6. `bye`.

Nothing is committed from a session that fails before step 3 completes;
re-running is harmless. Idle timeout 45 s, whole-session deadline 30 minutes.
Cursors only move forward except through `reset`.

Version compatibility today: only the channel version byte is enforced. The
`proto` and `schema` fields of `hello` are sent but not checked by the
receiver. Rows a peer sends in a format this build cannot parse are quarantined
rather than failing the session. See section 10.2.

### 6.7 Triggers (`SyncService`, `lib/app.dart`)

There is no periodic timer. Syncs start from:

| Trigger | Mechanism |
|---|---|
| App open | `sync.start()` then `requestAutoSync(2 s)` |
| App resume (Android lifecycle `resumed`) | `requestAutoSync(1 s)` |
| Local edit | `notes.changes` listener: `requestAutoSync(20 s)` unless a sync is running (a sync's own writes do not retrigger) |
| Manual | `syncAll()` / `syncPeer(id)` from the Sync screen |
| Incoming connection | a paired peer dialling us |

`requestAutoSync` debounces with a single timer and skips peers still in
back-off or already busy. Either device may dial; simultaneous dials are
resolved in favour of the lower device id. Removing a peer closes its active
channels and wins atomically over an in-flight batch.

### 6.8 Debugging sync

`SyncService.lastError[peerId]` (also `peers.last_error`) is shown on the Sync
screen; per-session counts are in `SyncOutcome`. Check that both devices are
open on the same network, their saved addresses are current, and Linux allows
inbound TCP 47380 and UDP 47381 from the current subnet. A stale firewall subnet
caused one-way phone-to-laptop sync to fail on 2026-11-21; see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md). Discovery is IPv4 broadcast and does
not cross routed subnets; client-isolated networks can block direct sync.
Tailscale is not verified. `NOTES_DATA_DIR` instances use an ephemeral port, so
pair them with a pasted code. If a peer was previously paired with another key,
remove the old peer and pair again. Quarantined rows can mean the other app is
newer or sent a damaged row.

### 6.9 Cloud sync (`lib/sync/cloud/`, `server/sync/`)

Cloud sync is optional and per device. `CloudService` owns sign-in, enablement,
upload and join flows, device management, status, polling and retry timers;
`CloudSyncEngine` owns record and attachment transfer. Detailed endpoints,
limits and protocol are specified in [CLOUD_SYNC.md](CLOUD_SYNC.md).

The deployed path is a TypeScript Cloudflare Worker with no runtime package
dependencies, a SQLite-backed Durable Object named `Coordinator` (library head
hint and one-time authorization codes), and a Neon Postgres database. Records,
blobs, devices and singleton-library state live in Postgres; the `plpgsql`
functions and append-only migrations `0001` and `0002` are in
`server/sync/migrations/`. `server/sync/scripts/build.mjs` bundles one source
into separate production and test bundles. Fake sign-in and `/v1/test/*` are
compiled only into the test bundle. The tests assert those strings are absent
from the production bundle.

Sign-in opens the system browser and uses Google's OpenID Connect `id_token`
with `response_mode=form_post`; no client secret is shipped to the app. The
Worker checks Google's signature, audience, nonce, verified email and the
configured owner subject. A PKCE verifier binds the one-time callback code to
the app. Signed access tokens last 12 hours; signed refresh tokens rotate, with
the previous refresh token accepted for 60 seconds to recover a lost response.
The app does not retain email or account subject. The server allows five active
devices total.

The client pulls ordered change pages and pushes bounded batches, uploading
folders before notes. It persists pull and push cursors and per-record server
revision/digest plus the common content base. Digests prevent echoing records
received from the server. A push conflict (409) causes the client to apply the
returned current rows and retry; a `missing` conflict entry clears stale local
revision bookkeeping so the row can be reinserted. It retries for at most five
rounds. Blob checks identify
missing and partial uploads; chunks resume from the returned length. Blob data
is SHA-256 checked before local storage. Malformed rows are kept in bounded
quarantine and retried on later pulls. Each page and batch updates rows and
progress together in local transactions.

Cloud `CloudService` phases are unavailable, off, signed out, signed in,
uploading, ready and paused. While active it polls the Durable Object head every
10 seconds while the window is visible and every 30 seconds while minimized (no
Neon request), pushes local changes 2 seconds after the last save (10 seconds
at most after the first save of a run), performs a Neon backstop at
start/resume/manual sync and at most hourly, and retries failures after
30 seconds, 2 minutes, 10 minutes and 30 minutes, except that the first head
poll that succeeds after a failure syncs immediately. Android pushes waiting
edits when it is paused, before it stops. Only one sync
runs at once; a request received during a run queues one follow-up. Android
stops polling when paused and runs foreground-only; Linux runs while open or
minimized and stops on quit. Active cloud sync suppresses LAN auto-sync; manual
LAN sync remains usable.

Uploading first creates and re-reads a verified export, then asks the user to
confirm. It initializes the library and uploads blobs, folders and notes before
marking it ready; progress is persisted so interrupted uploads can resume.
Joining performs a read-only dry run first: record digests, attachment hashes
and folder references must match, except an empty device can join by pulling.
Mismatch reports counts and does not link or mutate the local library.

Cloud rows are limited to 180 KiB and attachments to 20 MiB. Pushes contain at
most 50 rows/256 KiB; change pages default to 50 rows/256 KiB and cap at 100
rows/256 KiB; manifests page up to 500 records. Oversized local notes and
attachments stay local, are reported in status, and do not block other records.

The free-plan design uses Workers Free's 10 ms CPU per request and 100,000
requests per day, and Neon Free's 100 compute hours per month with scale-to-zero
after five idle minutes. Frequent head polls go through the Worker and
Coordinator, never Neon, so idle polling does not wake the database. The app
uses at most 14,400 head-poll requests per day for five devices polling
continuously (5 devices × 2 requests/minute × 1,440 minutes); other requests are
additional. Actual Neon compute usage depends on edits and transfer volume, and
the repository contains no deployment usage measurements. The app ships the
public endpoint `https://notes-sync.mmoptibuilds.workers.dev` by
default. `NOTES_CLOUD_URL` environment variable overrides the compile-time
`NOTES_CLOUD_URL` define, which overrides the default. When `NOTES_DATA_DIR` is
set, no default is used: the development instance has no cloud unless an
explicit URL is supplied, and its session is stored in that instance's own
directory. Production session tokens are held in platform secure storage.
The development session file is plain text and contains bearer credentials;
use it only with the isolated test Worker, protect the directory and remove it
with the test instance.

Worker secrets (`DATABASE_URL`, `SESSION_SECRET`, `OWNER_SUB`) are configured
only as Worker secrets. Public configuration includes the Google Web client ID,
Worker URL, redirect allowlist and environment. No secret belongs in source,
bundles, logs, CI output or documentation. Per-request logs contain request id,
route, status, duration and aggregate row/byte counts; never note content,
tokens, authorization headers, email, account subject or connection string.

## 7. Updates (`lib/update/`, `tool/linux/notes-update-helper`, `tool/release/`)

Trust model, key custody, rotation and expiry are in [UPDATES.md](UPDATES.md);
this section is the code map.

| Piece | File | Role |
|---|---|---|
| `UpdateController` | `update_controller.dart` | state machine behind automatic/manual checks and downloads, persisted ready state, explicit install, startup outcome |
| GitHub client | `github_release_client.dart` | `GET releases/latest` for `mmoptibuilds-commits/notes-app` over HTTPS, ETag-conditional, 1 MiB cap; 404 = "no stable release"; drafts and pre-releases excluded |
| HTTP seam | `update_http.dart` | `UpdateHttp` interface; `IoUpdateHttp` real, fakes in tests |
| Manifest | `manifest.dart` | verifies Ed25519 signature over the raw bytes of `notes-manifest.json` first, then validates schema, app id, channel, expiry, version, per-artifact platform/arch/filename/SHA-256/size |
| Pinned keys | `pinned_keys.dart` | `kPinnedKeys` (id `notes-release-1`), `kReleaseCertSha256`, `kUpdateAppId` |
| Download | `download_service.dart` | free-space check, manifest-scoped Range resume, complete-file hash before atomic rename, cancel |
| Installers | `android_installer.dart`, `linux_installer.dart`, `installer.dart`, `platform_installer.dart` | `UpdateInstaller` per platform |
| Versions | `version_compare.dart` | semver plus build number ordering |

Flow: automatic updates default on. After the first frame Notes restores any
ready artifact and starts a check a few seconds later; resume checks are gated
by the last successful check (24 h) and bounded failure backoff (one hour to
24 h, respecting GitHub `Retry-After`). Automatic work is disabled in a
`NOTES_DATA_DIR` instance and can be switched off in Updates settings. A manual
check is always available. The check fetches the stable release, manifest and
signature (bounded sizes), verifies the Ed25519 signature over the raw manifest
bytes, applies replay protection, and selects the platform artifact. A newer
signed release downloads in the background. Installation always needs the
user's confirmation.

Interrupted, cancelled or offline downloads keep a small metadata file with the
URL, release version, expected size, digest and ETag. Resume uses `Range` and
accepts only a matching `206 Content-Range`; ignored ranges or changed ETags
restart from byte zero. The complete artifact is hashed before atomic rename.
The ready record stores the raw manifest and signature, notes and asset address.
Android artifacts live in app-private `filesDir/updates`; Linux artifacts live
under XDG state. Restore and every install recheck signature, expiry, ordering,
size and digest. Android also repeats package, versionCode and pinned signer
checks. The root-screen banner takes its own layout space, offers **Install now**
and **Later**, and leaves Notes usable; Later hides it until the next launch.

Android: `AndroidUpdateInstaller` talks to the Kotlin `UpdaterPlugin` over the
method channel `com.mmoptibuilds.notes/updater`. It checks artifact hash, size,
versionCode, package id and that the single signing certificate matches
`kReleaseCertSha256` (kept equal to `tool/release_cert_sha256.txt` by a test),
then hands the APK to a `PackageInstaller` session with user action required.
Needs `REQUEST_INSTALL_PACKAGES`; without the per-app permission the controller
reports `BlockKind.installPermission`. `InstallResultReceiver` and
`InstallStatusHub` carry the result back. On Android 13+, Notes requests
`POST_NOTIFICATIONS` only after the user confirms Install. A private
`ACTION_MY_PACKAGE_REPLACED` receiver posts a notification only when the durable
pending-install versionCode matches the installed package, and its explicit
Activity `PendingIntent` returns to Notes on tap. If notifications are denied,
the next launch shows the one-time update result instead; the receiver never
starts an Activity in the background.

Linux: `LinuxUpdateInstaller` only updates a managed install (directory
`~/.local/opt/notes` containing `.managed-install`, written by
`tool/linux/install.sh`). After the user confirms and the app rechecks the
ready artifact, `onPrepareQuit` freezes editors and flushes their saves before
the installer creates a helper copy or starts a process. A failed or
unconfirmed save returns to the ready state with **Retry**; Notes, sync and the
database stay open, and the barrier runs again on retry. Only after the barrier
succeeds does the installer start the helper detached and call `onQuit`
(`AppServices.quitForUpdate`). The helper copies itself to a private temp
directory, waits for the app PID, validates the archive hash and size it was
given, checks free space on the install parent before staging, stages beside
the install, swaps directories with a retained `notes.previous`, and writes
status to `update.json`. It holds the per-user `flock` lock across the swap.
Linux startup checks that same lock before opening the database and waits
briefly for a running update to finish. The helper has no network or signature
code and never touches data, keyring or backups. A package-manager or unmanaged
install gets `BlockKind.unmanagedInstall`.

Signature requirement: with a key pinned, `verifyManifest` requires a valid
signature on both platforms. `AndroidUpdateInstaller.acceptsUnsignedManifest` is
`true` (Linux `false`), which matters only if `kPinnedKeys` were empty (see
section 11).

Release tooling: `tool/release/` (`keygen.dart`, `make_manifest.dart`,
`sign_manifest.dart`, `verify_manifest.dart`), `tool/verify_release_apk.dart`,
`tool/check_stable_version.dart`, `tool/package_linux.sh`. Tests under
`test/tool/` and `test/linux/` cover them. `kPinnedKeys`,
`tool/release_signing_pubkeys.json` and the README PEM must agree
(`test/update/manifest_test.dart`).

## 8. UI architecture (`lib/ui/`)

### 8.1 Structure

| Path | Role |
|---|---|
| `theme/app_theme.dart` | `AppPalette` (`ThemeExtension` with `background`, `card`, `cardBorder`, `raised`, `text`, `textMuted`, `textFaint`, `accent`, `onAccent`, `danger`, `codeBackground`) for `amoled`, `charcoal`, `light`; `AppMetrics` (radii, padding, `editorMaxWidth`); `AppMotion` (fast 120 ms, medium 220, page 260, scaled 0 / 0.5 / 1 by `AnimationLevel`); `buildTheme(AppSettings)` |
| `widgets/responsive.dart` | `pageMaxWidth` 640, `pageGutter`, `columnsFor`, `BoundedPage` for single-column pages |
| `widgets/touch.dart` | `touchTarget` 48 dp, `isTouchPlatform`, `hitSize`, `touchButtonMinimumSize`, `touchVisualDensity` (touch platforms get 48 dp, desktop stays compact) |
| `widgets/dialogs.dart`, `menus.dart`, `format.dart` | confirm/prompt dialogs, undo snackbars, context menus, date formatting |
| `library/` | library screen, header, folder strip, cards, move dialog, `library_layout.dart` metrics, `LibraryController` |
| `editor/` | `EditorScreen`, `EditorSession`, toolbar, completed section, embeds, style |
| `settings/` | `SettingsScreen` and sections, reusable rows (`settings_widgets.dart`), toolbar customisation, licences |
| `data/data_screen.dart` | import, restore, export, rollback UI |
| `sync/` | `SyncScreen`, `PairScreen` (show, enter, scan) |
| `updates/updates_screen.dart` | Updates screen |
| `help/`, `onboarding/` | Help topics (shortcut labels come from `shortcut_defs.dart`), first-use screen |
| `shortcuts/` | definitions, intents, focus guards |
| `splash.dart`, `brand_mark.dart`, `startup_error.dart` | launch surfaces |

Read colours from `AppPalette.of(context)` and timing from
`AppMotion.of(context)`; do not hard-code colours or durations. Use
`BoundedPage` for new single-column pages and `hitSize`/`touchButtonMinimumSize`
for controls so Android keeps 48 dp targets.

### 8.2 Library

`LibraryController` (`library_controller.dart`) holds what is shown (scope,
folder or unfiled, query, layout, sort, preview lines) and the selection. It
chooses its initial active view from `AppSettings.startupView`: Unfiled by
default, All notes, or the last active folder/view from `library.folder`. With
no live folders, Unfiled is represented by All notes because every active note
is unfiled; the saved startup preference remains Unfiled. Selecting a folder,
Unfiled or All updates `library.folder`, so Last viewed can restore it. New
notes opened from Unfiled have no folder. The folder strip and desktop sidebar
place Unfiled after All and before user folders; when folders exist, Unfiled
stays visible while selected or configured as the startup view, even at count
zero, and explains where foldered notes are shown. The controller loads the
list once per change, not per build, and reads summaries only (never bodies).
`repo.changes` and
`AppSettings` changes schedule a debounced reload;
while a route covers the library (`setCovered`) changes are only noted and the
reload runs when it is visible again. Each view (`viewKey`) keeps its own scroll
offset. Search is `NoteRepository.search`: every word must match, the last word
as a prefix, input is always literal text (`ftsQuery` never passes FTS syntax),
ranked by `bm25` with title weight 6, snippets built in Dart from a small window
for the first results only (SQLite `snippet()` took seconds on a 1 MB note).
`library_layout.dart` holds `wideBreakpoint` (720), card width targets, and
`gridCardExtent`, which mirrors card metrics so fixed-height grid cards fit at
any text scale.

On phone-width windows, search results use one-column rows when the saved layout
is Grid or Masonry; the saved layout itself does not change. The folder strip
scrolls the selected chip into view on first layout. The mobile overflow menu
opens below its 48 dp More button, lists destinations before View options, and
keeps Settings last; desktop retains a view-only menu. Its layout picker is a
single row of Grid, Masonry and List buttons, and the menu scrolls when its
contents exceed the available height. The phone All view is titled All notes;
empty active and Unfiled states give next steps that match the phone FAB or the
desktop New note button.

### 8.3 Editor

`EditorSession` (`editor_session.dart`) is the non-widget core, tested without
widgets. It owns the `QuillController`, the title controller, the
`ChecklistProjection` and autosave.

- Open writes nothing. A new note is created only on the first non-blank content
  (`flush` with no id and blank title and body does nothing).
- Autosave: 700 ms after the last edit; on failure retry every 3 s with status
  `failed`. `dispose` flushes; if that still failed, a background save handoff
  retries up to 2000 times and remains registered with `EditorSaveBarrier` so a
  Linux update cannot pass it without confirmation. The update barrier freezes
  editors while it flushes, then releases them again if a save fails.
- The visible document is never replaced by sync. A save that finds the stored
  version moved on produces a conflict copy (`onConflictCopy` shows a banner).
- A body that cannot be parsed (`loadError`) or a trashed note opens read-only
  and nothing is written.
- Note operations (pin, archive, trash, move) call `ensureStored()` first, then
  the repository.

`EditorScreen` hosts the toolbar (`ToolbarItem` order from settings), completed
items, image embeds (`att:` sources through `getAttachment`), copy as text and
Markdown, and the editor shortcut scope. Quill handles Ctrl+C and Ctrl+X for
selected editor text; cut edits flow through the session's normal autosave.
Quill's find-in-note handles Ctrl+F while the editor has focus.

### 8.4 Shortcuts (`lib/ui/shortcuts/`)

- `shortcut_defs.dart` is the source for bindings and Help labels: Ctrl/Meta+N,
  Ctrl/Meta+F, `/`, Ctrl+A, Delete, Alt+Left, Ctrl/Meta+Comma, F1, Escape and
  Ctrl/Meta+S. Ctrl/Meta+K is unimplemented and not bound.
- `shortcut_guards.dart` disables actions when a dialog, sheet, menu or another
  route is above the scope. Bare keys and Ctrl+A also require no `EditableText`
  or Quill focus; a disabled action lets typing continue. The scope restores
  focus after a field is clicked away from. Pushed screens bind their own scope.
- Escape closes a popup first, then clears search or selection, leaves search
  focus, and finally closes the editor pane or returns from a sub-view.

### 8.5 Settings, data, sync, updates screens

- Settings: sections in `settings_screen.dart` (`AppearanceSection`,
  `LibrarySection`, `EditorSection`, `SyncDataSection`, `AboutSection`) built
  from `SettingsRow`, `SegmentedRow`, `MenuRow`, `SwitchRow`, `SliderRow`.
  Adding a setting: add a typed accessor to `AppSettings`, a row in the right
  section, and a settings test.
- Data screen: Notebook import (inspect first, then import with a snapshot),
  Notes JSON export and restore (inspect, then apply), rollback of an import
  batch.
- Sync screen: addresses, paired devices, manual sync, pairing entry, and a
  cloud-settings entry when cloud is configured. Cloud settings expose sign-in,
  enablement, verified backup, confirmed upload, join check and device
  management. Pair screen
  shows a code, accepts pasted text, and scans on Android only
  (`Platform.isAndroid`).
- Updates screen: renders `UpdateStatus` from `UpdateController`; automatic
  check switch.

### 8.6 Desktop shell

`isDesktopSize` in `widgets/responsive.dart` enables the shell at 900 logical px
wide and 480 px high. Below either threshold the single-column library and
route-based editor are used. On desktop, `DesktopSidebar` is 232 px wide and
replaces the folder strip and floating new-note button. It contains All notes,
Unfiled when applicable, folders, Archive, Trash, Conflicts when present, and
Sync, Settings and Help at the bottom.

With no note open, the library uses the remaining width. Opening a note keeps
the library beside an embedded `EditorScreen`: the list column is 28% of the
window width, clamped to 280–340 px, and the editor takes the rest. New notes
open in the pane and are stored only after real content is entered. Switching
notes, closing the pane, or disposing it flushes the `EditorSession`; autosave
runs 700 ms after edits and retries after failures. If sync removes the open
note, the pane is dropped and disposing the editor flushes its session.

Resizing below either desktop threshold disposes the pane and returns to the
phone layout; the edit is flushed, but widening again does not reopen the pane.
Ctrl+F in the focused Quill editor opens find-in-note; elsewhere Ctrl+F and `/`
focus library search. The shared route and text-focus guards keep bare keys
from acting in text fields, the editor, or dialogs.

## 9. Testing

### 9.1 Layout of `test/`

| Directory | What it covers |
|---|---|
| `core/`, `data/`, `doc/` | clocks, vectors, database and migrations, repository, onboarding state, digest, projection (property tests), Markdown |
| `importer/` | legacy import (idempotency, rollback, interruption), export, restore, atomic write |
| `sync/` | merge and randomised 3-device convergence, secure channel attacks, peers, session fault injection, cloud pull/push/blob/upload/join/retry/crash and hostile-peer cases, service over real loopback sockets |
| `update/`, `linux/`, `android/`, `tool/` | updater logic with fakes, installer and helper scripts, Android manifest, backup and signing config, release tooling, README checks |
| `ui/` | widget tests per screen; `ui/library/`, `ui/editor/`, `ui/settings/`, `ui/shortcuts/`, `ui/updates/`, `ui/onboarding/`, `ui/help/`, `ui/splash/` |
| `e2e/persistence_test.dart` | real encrypted database and key file across close and reopen |
| `perf/` | regression ceilings and the seed-dataset harness (JIT VM, generous bounds, not benchmarks); see [PERFORMANCE.md](PERFORMANCE.md) |
| `private/` | optional legacy-backup audit; can read `private/*.json` unless `NOTES_PRIVATE_BACKUP` points to a missing file; synthetic cases are in the same test |
| `support/`, `fixtures/` | shared helpers and synthetic data |

### 9.2 Helpers

- `test/ui/library/support.dart`: deterministic synthetic `Seed` libraries;
  `test/support/screenshot.dart`: app fonts and PNG capture.
- `test/support/memory_transport.dart`: in-memory transport with frame fault
  injection. `test/update/` provides fake HTTP, installers and fixtures.
- `AppDatabase.open(null)` is in-memory; inject `wallClock`/`nowMs` for stable
  timestamps. Screenshots use synthetic data.

The normal tests use synthetic data. The optional `test/private/` audit can
read a user backup if one is present, so disable that input when running this
suite under the repository's no-real-data rule. Perf and sync tests that touch
disk set `NOTES_DATA_DIR` to a temp directory.

### 9.3 Running

```bash
export PATH="$HOME/development/flutter/bin:$PATH"   # Flutter 3.50.0
NOTES_PRIVATE_BACKUP=/path/that/does/not/exist flutter test  # all synthetic tests
flutter test test/sync                    # one area
flutter test test/sync/cloud              # cloud engine/service tests
flutter test test/live/cloud_live_test.dart # skipped unless CLOUD_LIVE_URL is set
flutter test --plain-name "substring of a test name" test/data
```

### 9.4 CI (`.github/workflows/ci.yml`)

CI runs `flutter pub get`, format, analyze and tests on pushes and pull
requests (Java 21, Flutter 3.50.0; actions pinned by SHA). It repeats the
Android release-signing and release-validation tests. CI does not build bundles
or APKs and has no signing key.

## 10. Changing things safely

Before any change: `dart format lib test tool`, `flutter analyze` (must say "No
issues found"), `flutter test`.

### 10.1 Schema change

1. Append a migration; never edit an earlier one. `schemaVersion` follows the
   list length.
2. Test an upgrade from the previous version with existing data (2.8).
3. Update synced row models and `writeRecord` together; check older-peer
   compatibility (10.2).
4. Migrations create `<db>.pre-v<N>.bak`; older builds refuse newer schemas, so
   rollback after migration may not start (UPDATES.md).
5. Backfill derived columns if their calculation changes.

### 10.2 Sync protocol change

- Preserve existing wire fields and types. Receivers ignore unknown row keys;
  missing or malformed required values are quarantined. `hello.proto` and
  `hello.schema` are not enforced, so gate incompatible session changes or bump
  `secureChannelVersion` before shipping.
- Cloud protocol changes must preserve Worker/client compatibility or be
  versioned deliberately. Apply append-only Neon migrations before deploying
  code that depends on them. Live tests may target only the isolated test Worker.
- Keep merge symmetric and idempotent; test convergence and session failures.
  Batches and cursors stay atomic and in sender order, and future clocks remain
  refused (D13). Do not weaken `SyncLimits` without a security reason in
  `DECISIONS.md`.

### 10.3 New setting

Typed accessor in `AppSettings` with a default and clamping; a row in the right
settings section; a test in `test/ui/settings/settings_test.dart`; use
`writeSilently` for bookkeeping that is not displayed. Settings are
per-device; if a value must sync it is not a setting.

### 10.4 New dependency

Add a line in `docs/DECISIONS.md` first (why, alternatives, platforms,
licence), update `docs/THIRD_PARTY_LICENSES.md`, and check both Android arm64 and
Linux x64 build. Prefer the existing packages (`cryptography` already provides
Ed25519 for updates).

### 10.5 UI change

Follow `.claude/skills/notes-ui-qa/SKILL.md`: layout sizes, themes, text scales,
keyboard/focus guards, semantics, reduced motion, and synthetic screenshots.
UI review must not write notes. Import Material through
`lib/ui/material.dart`. Shared files listed in `CLAUDE.md` require coordinator
review.

### 10.6 Data paths

Never write to `notes` or `folders` outside `NoteRepository`, never create sample
notes, and keep every multi-row write in one transaction. Anything that touches
`private/` prints counts and hashes only.

### 10.7 Release-affecting changes

- Version single source: `lib/core/app_version.dart` (`appVersionName`,
  `appBuildNumber`) must equal the `version:` line in `pubspec.yaml`
  (`test/core/app_version_test.dart`). The build number is the Android
  versionCode and must increase; check with `dart tool/check_stable_version.dart
  --stable`. The Linux archive name and `BUILD` file derive from `pubspec.yaml`
  (`tool/package_linux.sh`).
- Identifiers that must not change: application id `com.mmoptibuilds.notes`,
  binary `notes`, the Android signing key (a different key cannot update an
  installed phone), the pinned manifest key id `notes-release-1`.
- Changes to `lib/update/`, `tool/linux/`, `tool/release/`,
  `android/app/src/main/AndroidManifest.xml` or `kPinnedKeys` require the
  corresponding tests (`test/update`, `test/linux`, `test/tool`,
  `test/android`) and, for the key, agreement between `pinned_keys.dart`,
  `tool/release_signing_pubkeys.json` and the README.
- Follow `docs/RELEASE.md` and the `notes-release` skill; nothing is pushed,
  tagged, published or installed on the phone without the owner's yes.

## 11. Known limitations

Only items verified in code or tests:

- Very long notes are laid out in full: the editor (`flutter_quill`, `scrollable:
  false` inside one `SingleChildScrollView` with the title and completed
  section) lays out every block, so opening and scrolling cost grows with note
  length. Fixing it needs a lazily laid-out editor, not a setting change.
- LAN sync still requires devices to be reachable together. Optional cloud sync
  can transfer their changes at different times, while both have a valid
  session and a working connection.
- Sync is IPv4 only (TCP bind on `anyIPv4`, UDP broadcast discovery); discovery
  does not cross routed subnets.
- LAN sync has no periodic timer; it runs on app open/resume, after edits,
  manual sync, or an incoming peer connection. Cloud sync polls while the app
  is active. On Android cloud stops when the app is paused; it does not run
  while the app is closed.
- At most 5 devices in total (4 peers).
- Cloud line merge requires a stored common base and non-overlapping edits.
  LAN sync continues to preserve concurrent edits as whole-document conflict
  copies. A concurrent edit beats a delete-forever (an edit can undo a purge
  that arrived by sync).
- Two databases sharing one device id can produce equal version vectors with
  different content; current merge handling keeps both content versions.
- During an automatic cloud merge of a note that remains trashed, the trash
  register is stamped with the merge clock. A concurrent offline restore made
  before that merge can lose.
- Cloud notes above 180 KiB and attachments above 20 MiB do not sync; cloud
  status reports them while continuing with eligible records.
- Android cloud sync is foreground-only and stops when the app is paused. On
  pause it first tries to push waiting edits (up to 8 s); if the system freezes
  the process before that finishes, the edit waits until the app is opened
  again. Linux syncs while the window is open or minimized and stops when Notes
  quits.
- Changing the Worker's `OWNER_SUB` does not sign out devices that are already
  registered: revoke their rows (docs/RELEASE.md) when changing the owner.
- `GET /v1/head` checks the token signature and expiry but not device
  revocation, so that idle polls never touch Neon. A revoked device can read
  the library id, state and sequence number (no note data) until its access
  token expires, at most 12 hours.
- The Google consent screen is in Testing mode; only listed test users can sign
  in. Deploying the Worker requires the Cloudflare API or Wrangler, and Neon
  migrations are applied separately.
- `hello.proto` and `hello.schema` are sent but not enforced (10.2).
- Deleting a folder does not rewrite its notes' `folder_id`; queries join only
  live folders, so those notes show as unfiled while the stale id remains in the
  row.
- Checking or restoring a checklist item clears the editor's undo history.
- Exported Notes JSON is not encrypted. Losing the keystore entry loses the local
  database; recovery needs a paired device or an export.
- Android backup and transfer are disabled; the database cannot be restored from
  a system backup.
- Linux needs a running Secret Service (desktop keyring); without one startup
  fails with "Notes could not start". Dev instances use a plain key file.
- Linux QR scanning does not exist (paste only); Android is arm64 only
  (`UpdatePlatform.current()`), Linux x64 for updates.
- Linux self-update works only for a managed install (`~/.local/opt/notes` with
  `.managed-install`) and needs GNU tar, `flock`, `sha256sum`, `/proc`. After a
  newer build migrates the database, rolling back to an older build is not
  guaranteed to start (`DatabaseTooNewException`).
- An expired manifest or a device clock far in the future makes every update check
  report a verification failure; a retracted newer release blocks later checks
  until a newer one is published (replay guard).
- Legacy import preserves colour, tags, reminders and lock flag only in the import
  record; they have no UI. The importer was checked against backup version 11.
- Markdown export drops underline, colour, size and alignment.
- Not verified on hardware: Tailscale addresses; a real in-app update (needs a
  second signed release). Verified on the owner's Nothing Phone 2 and CachyOS
  laptop (2026-11-20/21): QR pairing, automatic LAN sync both ways, in-place
  APK upgrade with data intact, Linux install upgrade with data intact.
