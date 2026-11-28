# Changelog

All notable changes to Notes are recorded here.

## [1.3.2] - 2026-11-28

### Added

- Failed editor saves are kept in an encrypted, device-local recovery draft.
  The library offers a review screen, and a successful save clears the draft
  in the same transaction. If rich-text serialization fails, recovery keeps
  the latest title and text and warns that formatting or images may need review.
- Recovery opens the latest durable draft after claiming its editor lease.
  Closed-editor handoffs keep retrying with capped backoff until the encrypted
  copy is durable; a retry after permanent deletion preserves the tombstone and
  saves the unsaved text as a new note.

### Fixed

- First-run key and LAN identity initialization are serialized across
  processes. Concurrent database writers refresh the local sequence and HLC
  under the SQLite write lock. Migration backups are verified before atomic
  replacement, and import retention counts only readable Notes databases while
  keeping the newly written pre-import copy even after system clock changes.
- Recovery drafts have one active editor across Notes processes; stale saves
  cannot recreate a recovered or discarded copy.
- Signed update replay protection stores the verified release version and
  build together in one settings transaction, comparing persisted values so
  concurrent app windows cannot lower the mark.
- Cloud quarantine limits preserve LAN and unrelated pending records, retrying
  a page when a malformed row cannot be retained.
- Linux update archive validation works with Ubuntu's `mawk`; update failures
  now show safe retry guidance.
- System reduced-motion preference disables app motion without changing the
  saved animation setting.

### Changed

- The local database schema is version 5. Notes 1.3.1 and older cannot open a
  database after this release migrates it.

## [1.3.1] - 2026-11-25

### Fixed

- Cloud sync: signing in to an empty cloud library now opens the first-upload
  setup. In 1.3.0 the screen showed "Could not check the cloud library." and the
  library could not be uploaded. Only the empty-library answer changed; other
  cloud errors, including a genuinely changed library, behave as before.

## [1.3.0] - 2026-11-25

### Added

- Optional private cloud sync for Android and Linux. It is off by default and
  requires signing in with the owner's Google account and explicitly uploading
  a library. The server stores notes as readable JSON; cloud sync is not
  end-to-end encrypted. LAN sync remains available.
- Automatic merging of edits to different lines when a shared base is
  available. Conflicting edits are preserved for review.
- **Review edits** on the main note. Conflict copies no longer appear in the
  active or archive lists; they appear from the main note's review surface.
- Cloud settings for verified backup, confirmed upload, join checks and device
  management.

### Changed

- LAN automatic sync pauses on a device while its cloud sync is active. Manual
  LAN sync remains available.
- Cloud sync pushes a local edit 2 seconds after you stop typing (at most 10
  seconds after the first edit of a run) and checks for remote changes every 10
  seconds while the window is visible, every 30 seconds while it is minimized.
  Idle checks stay on the Durable Object and never wake the database.
- Local database schema is now version 4. Notes 1.2.0 devices continue to work
  together over LAN. After a 1.3.0 device migrates a database, an older build
  refuses to open that database.

### Fixed

- Android pushes waiting edits when the app is sent to the background instead
  of leaving them until the app is opened again.
- Edits made while offline are pushed on the first successful check after the
  connection returns, instead of waiting for the retry backoff (up to 30
  minutes).
- Rows received from the cloud no longer schedule a second, redundant push.
- Concurrent cloud edits to separate lines are combined automatically; edits
  that overlap retain a reviewable conflict copy.

### Security

- Cloud sign-in is limited to the configured owner's verified Google account.
  Cloud data is readable by the server and is not end-to-end encrypted.
- Cloud sync remains opt-in; nothing uploads before the user signs in and
  confirms the library upload.

## [1.2.0] - 2026-11-24

### Added

- A warning before every manual JSON backup export: the file is unencrypted, so
  anyone who can access it can read your notes and attachments. Choose
  **Cancel** or **Continue**; Cancel exports nothing.
- A manual **Release build checks** GitHub workflow that builds Android arm64
  and Linux x64 packages with a temporary CI-only certificate. It publishes
  nothing and is not a release.

### Fixed

- Linux in-app updates now confirm that every open or recently closed note is
  saved before the update helper starts. If a save fails, Notes stays open with
  your edits and the update waits for **Retry**.

### Changed

- The `main` branch is protected from deletion and force pushes. Ordinary
  direct pushes are unaffected.

## [1.1.0] - 2026-11-21

### Added

- Choose whether Notes opens to Unfiled, All notes or the last viewed library
  view. Unfiled is the default.
- Automatic update downloads, a ready-to-install prompt, safe resume after an
  interrupted download and restoration of a verified ready update after a
  restart.
- An Android “Notes updated” notification with a shortcut back to the app.
- Linux updates that relaunch Notes after replacing a managed installation.

### Changed

- Redesigned the overflow menu, with destinations first and Settings last.
- Placed Unfiled after All notes in the library navigation and titled the phone
  view “All notes”.
- Improved text contrast, card borders and empty-library guidance.
- Kept phone search results in one column and improved the settings layout at
  larger text sizes.

### Fixed

- Local edits made during a sync now receive a follow-up sync.
- Update downloads safely restart when a server cannot confirm a partial file;
  failed Linux updates reopen the previous app.
- Improved touch targets and toolbar accessibility at small and large sizes.

### Security

- Release updates continue to use the existing signed manifest and pinned
  platform signing checks; the trust keys and trust chain are unchanged.
- A partial update resumes only when the server confirms the same strong ETag.
  Notes verifies the complete file again before offering installation.

## [1.0.0] - 2026-11-21

### Added

- Encrypted local notes with rich-text editing, search, folders, pinning,
  archive, Trash, and three appearance themes.
- Direct encrypted sync between up to five of the owner's devices, with QR or
  copied-code pairing.
- Markdown import and export, legacy Notebook backup import, and Notes JSON
  export and restore.
- Android phone and Linux desktop layouts, including a persistent desktop
  sidebar and side-by-side editor.
- First-run welcome and Help screens, keyboard shortcuts, and settings for
  appearance, editing and library layout.
- Signed stable update checks and platform installers for Android and managed
  Linux installs.

### Security

- Encrypted the local database and authenticated direct device sync.
- Verified stable update manifests and artifacts before installation.
