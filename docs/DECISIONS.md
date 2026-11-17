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
