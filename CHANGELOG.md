# Changelog

All notable changes to Notes are recorded here.

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
