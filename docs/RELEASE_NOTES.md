# Notes 1.3.1

A fix for cloud sync in 1.3.0. Nothing else changed.

## What's fixed

- **First cloud upload.** After signing in to a cloud library that has never been
  used, Notes 1.3.0 showed "Could not check the cloud library." instead of the
  upload setup. It now opens the setup, where you create a verified backup and
  confirm the upload yourself. Nothing is uploaded until you confirm.

## Upgrading from 1.3.0

Open **Settings → Updates** and confirm the install on Linux, or install the
APK over the existing app on Android. Your notes, paired devices and cloud
sign-in are kept. There is no database change in this release.

---

# Notes 1.3.0

Notes is a personal, offline-first notes app for Android and Linux. Notes stay
in an encrypted database on your device. Cloud sync is optional and off by
default.

## What's new

- **Optional private cloud sync** between your Android and Linux devices, across
  networks. It needs the owner's Google account, a one-time confirmed upload of
  your library and a server you control (a Cloudflare Worker and a Neon
  database, both free tiers). The server stores your notes as readable JSON:
  cloud sync is not end-to-end encrypted. LAN sync still works and stays
  available.
- **Automatic, fast sync.** While cloud sync is on and Notes is open, a saved
  note usually reaches your other open devices within fifteen seconds, with no
  need to tap Sync now. Edits made offline are sent as soon as the connection
  returns, and Android sends waiting edits before it goes to the background.
- **Edits to different parts of a note are merged automatically.** When two
  devices change the same lines, Notes keeps the other version and shows
  **Review edits** on the main note.
- **Cloud settings** for a verified backup, the confirmed upload, join checks
  and device management.

## Upgrading from 1.2.0

Open **Settings → Updates** and confirm the install on Linux, or install the
APK over the existing app on Android. Your notes and paired devices are kept.
The first start of 1.3.0 upgrades the local database and writes a backup copy
next to it (`notes.db.pre-v4.bak` on Linux). Export a Notes JSON backup first.

A 1.2.0 build cannot open a database that 1.3.0 has upgraded. To go back, see
the [schema 4 rollback steps](RELEASE.md#historical-schema-4-upgrade-and-rollback-120-to-130).
On Android, rollback requires a saved export and a reinstall.

---

# Notes 1.2.0

Notes is a personal, offline-first notes app for Android and Linux. Notes stay
in an encrypted database on your device. There are no accounts, analytics or
cloud service.

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
