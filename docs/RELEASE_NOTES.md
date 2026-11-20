# Notes 1.0.0 release notes (candidate 1.0.0+20261121)

Notes is a personal, offline-first notes app for Android and Linux. There are no accounts, no cloud service and no analytics.

## What is in 1.0.0

- Rich-text notes with checklists, folders, pinning, archive and Trash, search and sorting. Grid, masonry and list layouts; AMOLED black, charcoal and light themes.
- Notes are stored in an encrypted local database. The key is kept in the Android Keystore or the Linux keyring.
- Import of a legacy Notebook backup, and export and restore of Notes' own backup file.
- Sync between your own devices over the same network: pair with a QR code or code, then changes sync automatically while both apps are open. "Sync now" is always available.
- A one-screen welcome on a fresh install, a searchable offline Help screen (Settings, About, Help, or F1 on Linux), and desktop shortcuts: Ctrl+N, Ctrl+F, `/`, Ctrl+Comma, F1, Escape, Ctrl+S, Ctrl+A, Delete, Alt+Left.
- Android: 48 dp touch targets, a black launch screen with no white flash, and large-text fixes in the library and editor.

## Install

- Android (arm64, Android 7.0+): install `app-release.apk`. It is signed with the same key as earlier builds, so it updates an existing Notes install in place and keeps its notes. Do not uninstall first.
- Linux (x64): extract `notes-1.0.0-linux-x64.tar.gz`, run `./install.sh` for a per-user install (no sudo), or run `bundle/notes` directly.
- Verify downloads with the `.sha256` file and `sha256sum -c`.

## Upgrade

Install over the existing app. The database upgrades automatically. Existing users never see the welcome screen.

## Before you rely on it: back up

- Notes export files are plain JSON and are **not encrypted**. Store them somewhere you trust.
- Android's system backup is turned off for this app and cannot restore the encrypted database. If you reset the phone or reinstall, restore from a Notes export.
- Keep your own copy of an export from each device before upgrading.

## Known limitations

- Sync works over a local network while both apps are open. Android does not sync in the background while the app is force-stopped. Tailscale or other remote paths are not part of 1.0.0.
- On Linux, the firewall must allow TCP 47380 and UDP 47381 from your local network for pairing and sync.
- Keyboard shortcuts were covered by automated tests only; they have not yet been checked by hand with a real keyboard.
- Licence status: upstream permission for the project's origin is unresolved. See `docs/PROVENANCE.md` and `docs/THIRD_PARTY_LICENSES.md`. This blocks public distribution, not personal use.
