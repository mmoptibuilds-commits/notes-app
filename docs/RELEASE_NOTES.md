# Notes 1.0.0

Notes is a personal, offline-first notes app for Android and Linux. Notes stay
in an encrypted database on your device. There are no accounts, analytics or
cloud service.

## Highlights

- Write and organize rich-text notes with headings, lists, checklists, links and
  code blocks. Search, pin, sort, file, archive and trash notes.
- Use the phone layout on Android or the Linux desktop layout with a persistent
  sidebar and an editor pane beside the library.
- Choose AMOLED, charcoal or light appearance and adjust text size and editor
  preferences.
- Import Markdown files as notes and export a note as Markdown. Import a legacy
  Notebook backup or export and restore a Notes JSON backup.
- Pair up to five of your own devices with a QR code or copied code, then sync
  directly over a local network using an encrypted connection.

## Install and verify

Download the Android arm64 APK or Linux x64 archive from the
[Notes releases page](https://github.com/mmoptibuilds-commits/notes-app/releases).
For Linux, verify the signed manifest and archive hash using
[Verify a Linux download](../README.md#verify-a-linux-download) before
extracting the archive, then follow the [Linux installation guide](INSTALL.md).
The APK must be signed with the same certificate as an existing Notes install
to update it in place. Do not uninstall first if you need to keep local notes.

## Known limitations

- Sync is direct between paired devices and requires a route between them. It
  works best on the same local network; there is no relay service. Tailscale has
  not been verified.
- Android does not sync while Notes is closed. Open Notes on both devices or
  tap **Sync now**.
- A maximum of five devices can be paired.
- Concurrent edits to one note are kept as a conflict copy; Notes does not merge
  text automatically.
- Notes JSON exports are not encrypted. Android system backup and device
  transfer are disabled, and losing the local encryption key makes that
  database unreadable. Keep a Notes export somewhere safe and maintain another
  paired device.
- Markdown export preserves text and supported formatting, but drops underline,
  colour, font size and alignment.
- A real in-app update has not yet been verified end to end; that check needs a
  second signed stable release.
