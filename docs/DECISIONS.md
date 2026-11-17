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
formats are re-implemented. The user reports having the author's permission;
its scope must be confirmed in writing before publishing anything.

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
