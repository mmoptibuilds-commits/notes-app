# Notes

An offline-first notes app for **Android and Linux**, built with Flutter. Notes stay on-device by default, with optional direct device-to-device sync.

> **Early preview.** The Android app launches on a real device and the core editor, data layer, and sync engine have automated test coverage. Real-device pairing/sync, complete import verification, and in-place update testing are not yet confirmed. See [the development plan](docs/PLAN.md).

## Screenshots

<p align="center">
  <img src="docs/screenshots/library.png" alt="Notes library with folders and note previews" width="205" />
  <img src="docs/screenshots/note-editor.png" alt="Rich text and Markdown note editor" width="205" />
  <img src="docs/screenshots/settings-appearance.png" alt="Appearance and library settings" width="205" />
  <img src="docs/screenshots/settings-editor-data.png" alt="Editor, sync and data settings" width="205" />
</p>

## Features

- **Local-first storage:** notes saved in an encrypted local SQLite database; no account required.
- **Rich text editing:** headings, lists, checklists, blockquotes, code blocks, links and inline formatting.
- **Organized library:** folders, search, grid/masonry/list layouts, sorting and preview controls.
- **Appearance:** AMOLED, charcoal and light themes; adjustable typography and animation preferences.
- **Import and export:** legacy Notebook backup import, complete JSON export and Markdown note export.
- **Device sync:** peer-to-peer pairing and encrypted sync support under development; actual cross-device behavior still needs device testing.

## Platforms

| Platform | Status |
| --- | --- |
| Android | Preview build; real-device launch verified |
| Linux | Native Flutter build; local launch and keyring persistence verified |

## Build from source

Requires Flutter and a supported Android or Linux toolchain. The full environment and verification steps are in [CLAUDE.md](CLAUDE.md).

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
# Linux desktop build:
flutter build linux --release
```

**Android signing:** Official update-compatible releases must be built with the project's existing private signing key, which is intentionally kept outside this repository. A locally built APK without that key uses a different signing identity and may not update an existing installation.

## Project documentation

- [Product requirements](docs/PRODUCT.md)
- [Implementation progress and verification](docs/PLAN.md)
- [Architecture decisions](docs/DECISIONS.md)
- [Build and development instructions](CLAUDE.md)

Latest source snapshots and release notes are on the [Releases](https://github.com/mmoptibuilds-commits/notes-app/releases) page.
