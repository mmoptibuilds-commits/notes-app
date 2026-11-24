# Decisions

Only consequential choices. Newest at the bottom.

## D1. Flutter 3.50.0 + Dart 3.14, pinned
The user prefers Flutter; it covers Android and Linux from one codebase and
keeps Quill Delta compatibility with the legacy data. Installed in user space
at `~/development/flutter`. Verified: Linux release build succeeds from the
project path (which contains a space).

## D2. Editor: flutter_quill 11.6.0
Same editor family and document format (Quill Delta) as the legacy app, so
imported notes need no lossy conversion. Actively published (2026-09).

## D3. Material import stays on the SDK library
Flutter 3.47+ deprecates `package:flutter/material.dart` in favour of the
`material_ui` package. flutter_quill still imports the SDK library; mixing the
two creates two separate `Theme` hierarchies. The whole app therefore imports
Material through one barrel, `lib/ui/material.dart`. When flutter_quill
migrates, change that one export.

## D4. Storage: `sqlite3` 3.9 with the SQLite3 Multiple Ciphers build
Chosen over upstream's `sqflite_sqlcipher` (no Linux support) and over the
`*_flutter_libs` packages (end-of-life). The `sqlite3` package bundles a
prebuilt library per platform through Dart build hooks;
`hooks.user_defines.sqlite3.source: sqlite3mc` selects the encrypted build.
Verified by test on Linux: database file is not plaintext, wrong key is
rejected, FTS5 is compiled in (SQLite 3.54, ChaCha20-Poly1305 cipher).
Not yet verified on Android arm64.

No ORM. Plain SQL with a small migration runner keyed on `PRAGMA user_version`.
Calls are synchronous on the UI isolate; writes are small and debounced. Move
to a worker isolate only if profiling shows dropped frames.

`journal_mode=WAL`, `synchronous=NORMAL`: a killed process loses nothing
committed; only an OS crash or power cut can lose the last moments, never
corrupt the file.

## D5. Database key lives in the platform keystore
A random 32-byte key in Android Keystore / the Linux Secret Service
(`flutter_secure_storage`). If the database file exists and the key is
missing, the app refuses to start rather than create an empty database over
it. Trade-off accepted: losing the keyring loses the local copy; sync peers
and exports are the recovery path.

## D6. Sync model: per-note registers, version vectors, conflict copies
- Each device has a random id and a hybrid logical clock (HLC).
- Note content (title + body) carries a version vector. On merge: dominated
  loses, dominating wins, concurrent means conflict.
- A conflict keeps the newer HLC as the note and writes the other version to a
  separate "conflict copy" note with an id derived from the note id and the
  losing version, so every device creates the same copy exactly once.
- Metadata (pinned, archived, folder, trashed) are last-writer-wins registers,
  each with its own HLC, so moving a note never conflicts with editing it.
- Deleting forever is a content write that leaves a tombstone. A concurrent
  edit beats a concurrent purge.
- A content edit newer than a trash action restores the note from Trash.
- Change queue: every local or merged change stamps the row with the next
  local sequence number. Per peer, the device stores the highest sequence the
  peer has confirmed. "Pending" is rows above that mark; nothing else is
  needed for durable queuing.
- Whole-document merge, not a text CRDT: five personal devices rarely edit
  the same note concurrently, and a kept copy is easier to trust than an
  automatic merge.

## D7. Legacy imports are deterministic
An imported note keeps its legacy id. Its version vector is
`{"legacy:<content-hash>": 1}` and its clocks derive from the legacy
timestamps, so importing the same backup on two devices produces identical
rows that sync as equal instead of conflicting.

## D8. Completed checklist section is a projection
Upstream removes checked lines from the document on open, keeps only their
trimmed plain text, and appends them back on save. Here the stored Delta keeps
every line in place with its formatting. The editor shows the unchecked part;
checked lines are tracked beside it with anchors that follow edits, and are
re-inserted at their anchors on save. Opening a note writes nothing.

## D9. Images are blobs inside the database
Content-addressed (SHA-256) rows in an `attachments` table. Encrypted with the
rest of the data, written atomically with the note, synced on demand by hash.
Simpler and safer than loose files for a personal-scale library.

## D10. No state-management package
`ChangeNotifier`/`ValueNotifier` and constructor injection. The app has a
handful of long-lived objects; a framework would add more than it removes.

## D11. Identifiers
Android application id and Linux app id: `com.mmoptibuilds.notes`. Binary:
`notes`. Linux data: `~/.local/share/com.mmoptibuilds.notes/`, overridable
with `NOTES_DATA_DIR`. Deliberately different from upstream's
`com.saadhjawwadh.notebook` so both apps coexist.

## D12. Upstream source is reference only
`SaadhJawwadh/Everything-App` has no licence file (checked 2026-11-17), so by
default all rights are reserved. Nothing is copied from it; behaviour and data
formats are re-implemented. Update 2026-11-21: the owner publishes Notes as
independent work without relying on any permission from the upstream author
(see PROVENANCE.md).

## D13. Sync protocol invariants the transport must keep
Found while testing the merge (`test/sync/merge_test.dart`):
- **Batches are applied atomically.** When devices make independent edits,
  the device that resolves first writes the losing version as a conflict copy
  and a merged note whose version includes both. If a peer received the
  merged note without the copy, it would overwrite its own edit with
  nothing left to show for it. Therefore a received batch is applied in one
  transaction, only after it has arrived completely, and the sender emits
  rows in change order (the copy is written before the note that resolved it).
- **Records, not operations.** Peers exchange whole note/folder rows; the
  receiver merges with `RemoteApplier` (idempotent, order-independent).
- **Future clocks are refused.** A peer clock more than 2 days ahead aborts
  the batch (`ClockSkewException`) instead of dragging this device's clock
  forward permanently.
- **Folders** merge by id; the same name created on two devices gets the same
  id (`derivedId`), so pairing does not duplicate folders.
- Convergence is checked by randomised simulation: 3 devices with skewed
  clocks, dropped/duplicated/reordered exchanges, 8 seeds, final states
  compared row for row.

## D14. File picking: `file_selector`
Official Flutter package with Android and Linux implementations; used only to
choose an image to attach. Chosen over `file_picker` (larger, more platforms
than needed) and `image_picker` (no Linux).

## D15. Independent security review of the sync stack (2026-11-17)
Reviewer: OpenAI Codex CLI (`gpt-6-luna`), read-only, given only `lib/sync`,
the models and the design notes (no repo history, no private data). Seven
findings; outcome of each:

| # | Finding | Outcome |
|---|---|---|
| 1 | Unauthenticated connections can hold every inbound slot; unbounded frame queue | Fixed: separate handshake/session slots, 2 handshakes per address, 6 s handshake timeout; socket reads pause (TCP backpressure) when 2 frames are waiting. Tested. |
| 2 | One pairing code could be consumed by several concurrent handshakes | Fixed: `PairingHost.consume()` is an atomic claim; the losing handshake is closed. Tested with two scanners racing. |
| 3 | UDP discovery tag is stable and reveals the port | Fixed in part: tag now rotates daily (accepts ±1 day). The listening port is still revealed to the local network; accepted. |
| 4 | A peer can advance our receive cursor past rows it omitted | Accepted as outside the threat model: a paired device is trusted with all notes and could already rewrite or purge them. The *honest* variant of this problem was real and is fixed: after a peer is restored from an older copy, its numbering restarts, and our cursor (which only moves forward) would have skipped its later rows. The peer now flags `reset` and the cursor is set, not raised. The test fails without the fix. |
| 5 | Unreadable rows are skipped while the cursor advances | Kept the skip (retrying a permanently bad row would block all sync) but nothing is discarded any more: rows go to a `quarantine` table (schema v3, newest 500 kept) and are counted in the outcome. |
| 6 | Attachment traffic and `blobmissing` replies unbounded | Fixed: 512 MiB image bytes per session, one reply per requested hash, 30-minute session deadline. Tested. |
| 7 | Equal version vectors with different content silently discarded one | Fixed: treated like concurrent edits; both versions kept. Tested. |

Reviewer's "checked and sound": handshake transcript binding, DH input
order, directional keys, key confirmation, counters, no downgrade path, pairing
secret strength and expiry, attacker without the secret cannot pair, batches
applied atomically, attachments stored only after hash match.
Not yet reviewed by anyone else: `lib/doc/checklist_projection.dart`,
`lib/importer/`, the editor session.


## D16. Second independent review (importer, checklist projection, editor session)
- Disposing the editor after a failed save discarded the only copy of the
  text. Fixed: the pending text is handed to a background retry that outlives
  the editor (tested).
- "An edit can undo a purge that arrived by sync": accepted. Rule D6 says an
  active edit beats a concurrent delete-forever, because losing typed text is
  worse than keeping a note the user was still editing.
- Reviewer found no loss in checklist split/merge, open-writes-nothing, or
  import/rollback transactions (it could not see migrations.dart).

## D17. No Android cross-platform transfer rules without an iOS counterpart
Android's official Auto Backup documentation (developer.android.com/identity/data/autobackup,
checked 2026-11-20) says `<cross-platform-transfer platform="ios">` requires
`bundleId`, `teamId`, and `contentVersion` parameters so Android can match the
target app. Notes has Android and Linux builds, but no iOS counterpart, so
there are no valid iOS identifiers to supply and inventing them would be
incorrect. Keep the existing extraction XML unchanged. The app disables backup
with `allowBackup=false`; its cloud-backup and device-transfer sections each
exclude every data domain. `test/android/backup_config_test.dart` checks these
protections and confirms no cross-platform-transfer section is declared.

## D18. In-app update checks, and what authenticates an update
- **Source and channel.** Updates come from the public GitHub Releases API for
  `mmoptibuilds-commits/notes-app` (`releases/latest`, which excludes drafts and
  pre-releases). A 404 means "no stable release published" and is never shown as
  "up to date". Only HTTPS, bounded response sizes, ETag-conditional requests,
  no token, no HTML scraping, a generic User-Agent.
- **Automatic checks are on by default, opt-out in Settings.** At most one
  request per 24 hours, about 30 s after the first frame, never in a
  `NOTES_DATA_DIR` development instance, never blocking startup, never
  installing anything. The only information that leaves the device is what any
  HTTPS request reveals (IP address, a generic User-Agent). This is a deliberate
  exception to "no network unless syncing"; the Updates screen says so and the
  switch turns it off. Bookkeeping uses `AppSettings.writeSilently` so a check
  does not rebuild the app or re-run settings listeners.
- **One signed manifest per release** (`notes-manifest.json` plus a detached
  Ed25519 signature) binds app id, channel, version, build number, expiry, and per
  artifact the platform, architecture, exact filename, SHA-256 and size. The
  signature is verified over the raw manifest bytes before parsing, against keys
  pinned in the app (`lib/update/pinned_keys.dart`). No downgrade, no replay of a
  lower manifest, no unsigned fallback on Linux.
- **Production signing key.** Generated by the owner on 2026-11-21
  (`notes-release-1`, DER SPKI SHA-256 `6947c0cb…0ed0471`, full value in
  UPDATES.md); only the public key is committed. Before that date Linux
  self-update was blocked by design.
- **Android authenticity rests on the APK signing certificate.** The downloaded
  APK must carry the pinned release certificate (`tool/release_cert_sha256.txt`),
  the package id `com.mmoptibuilds.notes` and a higher versionCode; the OS
  installer enforces the same and asks the user. Installation uses a
  `PackageInstaller` session with user action required (never silent, no
  FileProvider, so the database directory cannot be exposed). The manifest
  signature is additionally required whenever a key is pinned. A Google Play
  distribution would have to use Play's own updates instead.
- **Linux replacement is done by a helper after the app exits**, user-scoped
  only, into `~/.local/opt/notes` with a same-filesystem staging directory, a
  retained `install.previous`, and a lock. The helper never touches the data
  directory, keyring, backups or pairing. Rollback is automatic only when the swap
  itself fails: once a newer build has migrated the database, an older build
  refuses it (`DatabaseTooNewException`), so a later manual rollback is unsafe
  across schema changes.
- **No new dependency**: the existing `cryptography` package provides Ed25519.

## D19. Linux desktop smoke tests use Flutter's `integration_test`
The SDK-bundled `integration_test` package is a dev-only dependency. It lets the
Linux smoke test launch the app in a real GTK window with Flutter's native
engine, then verify encrypted SQLite persistence across a close and reopen.
Widget tests remain useful for layout and interaction coverage, but they cannot
prove the native desktop runner and on-disk database work together.

## D20. Optional private cloud sync through a Cloudflare Worker and Neon
Accounts, a cloud relay and an always-on server were excluded from the first
design. The owner's devices are never reachable at the same time often enough
for LAN sync alone, so Notes 1.3.0 adds an **opt-in** cloud path:

- **Shape:** a Cloudflare Worker (TypeScript, Workers Free) in front of a Neon
  Postgres project (Free plan), at a total cost of $0. The server is a thin
  revisioned record store with a change feed and a blob store; it authenticates
  one Google account (the owner's verified account ID) and merges nothing. See
  [CLOUD_SYNC.md](CLOUD_SYNC.md).
- **Not end-to-end encrypted.** The server stores notes as readable JSON and
  its operator (the owner) can read them. This was chosen deliberately for a
  single-owner private deployment; transport is HTTPS, tokens are short lived and
  per device, and secrets exist only as Worker secrets. Anyone who wants the old
  "nothing leaves my devices" model keeps cloud off (the default) and uses LAN
  sync.
- **Why not a managed sync product or Firebase:** a per-vendor account with its
  own data model, quotas and terms, versus about a thousand lines we control and
  can delete. **Why not Cloudflare D1 or Durable Object storage as the store:**
  the owner asked for Neon, and Postgres keeps the data portable.
- **Free-plan constraints drive the design:** 10 ms CPU per Worker request
  (no server-side merging, no byte processing), and Neon's 100 CU-hours a month
  with scale to zero after five idle minutes (an idle "anything new?" poll is
  answered by a Durable Object and never wakes Neon).
- **Sign-in:** OpenID Connect `id_token` in the system browser, verified by the
  Worker; no OAuth client secret exists, and no Google SDK is added.
- **LAN sync is unchanged on the wire** and keeps working with 1.2.0 devices.

## D21. Automatic text merge for concurrent edits (supersedes "no text merge")
Concurrent edits to one note used to keep both versions as a conflict copy,
always. Cloud sync makes concurrent edits more common (devices sync while the
user works), so edits to **different lines** are now merged automatically with a
three-way line merge against the last cloud-synced version of that note. Edits
that overlap keep the later version as the main note and preserve the other as a
conflict copy that the editor presents as **Review edits**. Nothing is ever
dropped silently. The merge lives in pure Dart (`lib/doc/line_merge.dart`,
`lib/sync/three_way.dart`), has property tests, and is used only by the cloud
path; LAN sync still has no base version and keeps whole-document conflict
copies.
