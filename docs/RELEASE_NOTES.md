# Notes 1.2.0 (build candidate)

Notes is a personal, offline-first notes app for Android and Linux. Notes stay
in an encrypted database on your device. There are no accounts, analytics or
cloud service. This release is not published yet.

## What's new

- Exporting a JSON backup now warns that the file is unencrypted and asks you
  to confirm each time. Cancel exports nothing.
- Linux in-app updates save your open notes before the update starts. If Notes
  cannot confirm a save, it stays open with your edits and offers **Retry**
  instead of installing.

## Upgrading from 1.1.0

Open **Settings → Updates** and confirm the install when the update is ready.
Your encrypted notes database and paired devices are kept when you update.
Verification and signing are unchanged; see the 1.1.0 notes below for manual
installation.

---

# Notes 1.1.0

Notes is a personal, offline-first notes app for Android and Linux. Notes stay
in an encrypted database on your device. There are no accounts, analytics or
cloud service.

## What's new

- Choose Unfiled, All notes or Last viewed as the library's start view. Unfiled
  is selected by default.
- Stable updates can download in the background when automatic updates are
  enabled. A verified update stays ready across app restarts and Notes offers
  **Install now** or **Later** when it is ready.
- Android shows a “Notes updated” notification after an update. Android 13 and
  newer may ask for notification permission when you confirm installation;
  denying permission does not stop the update.
- Linux in-app updates close and relaunch Notes after updating a managed
  installation.
- The library menus, phone search, text contrast and large-text settings layout
  have been improved. Sync also follows up on edits made during a sync session.

## Upgrading from 1.0.0

Notes 1.0.0 finds 1.1.0 with its update check; open **Settings → Updates**, tap
**Download**, then **Install…** and confirm. (1.0.0 only checks automatically;
background downloads start with 1.1.0.) From 1.1.0 on, automatic updates are
enabled by default and download in the background; you still confirm
installation. Android hands the verified APK to its system installer. Linux
updates relaunch the app after the managed program files are replaced. Your
encrypted notes database and paired devices are kept when you update.

For a manual installation, download the Android arm64 APK or Linux x64 archive
from the [Notes releases page](https://github.com/mmoptibuilds-commits/notes-app/releases).
Linux users should verify the signed manifest and archive hash using
[Verify a Linux download](../README.md#verify-a-linux-download) before
extracting. An Android APK must use the same signing certificate as your
existing installation. Do not uninstall first if you need to keep local notes.

---

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
