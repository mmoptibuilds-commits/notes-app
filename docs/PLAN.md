# Plan

Status words: **verified** means supported by an automated test or a recorded
run; **unverified** means the check has not been done. Verification facts are
dated individually where known.

## Current position

The automated suite has over 1,200 tests (two skipped) and passes locally and
in GitHub Actions on every push of `integration/final-polish`. A real backup import was
separately checked by counts only: 44 notes, 0 failures; no note content was
recorded.

Android export uses the system save picker (`ACTION_CREATE_DOCUMENT`), and
imports can read a content URI. Restoring Notes' own JSON export includes a
preview, confirmation, pre-restore database snapshot, and one transaction.
Sync collision handling and quarantine retry are implemented.

An Android x86_64 emulator running Android 15 and Linux sync were verified.
Linux sync paired by entering a code and covered conflicts and deletions, with
476-note convergence. On 2026-11-20 the release-signed APK was installed in
place over the previous build on a Nothing Phone 2 (arm64, Android 16) with the
existing notes and folders intact, the phone paired with the Linux app by QR
code, and automatic two-way sync worked. Tailscale has not been checked.
Release builds fail when Android signing configuration is absent. CI has run
and passes. No stable release has been published; `v1.0.0-preview.1` is a
pre-release with no assets.

## Next actions

1. Complete Android and Linux release checks in [RELEASE.md](RELEASE.md).
2. Provision an offline production signing key for update manifests
   ([UPDATES.md](UPDATES.md)); until then Linux self-update stays blocked.
3. Obtain written upstream permission with publication and distribution scope
   settled before any public release.

## Acceptance matrix

| Check | Status | Evidence or remaining gap |
|---|---|---|
| Automated tests | Verified | Over 1,200 tests locally and in CI |
| Legacy backup import | Verified | Real backup: 44 notes, 0 failures; counts only |
| Notes JSON export and restore | Verified | Android system save picker; content URI import; restore preview, confirmation, snapshot, transaction |
| Android app launch and persistence | Verified | x86_64 Android 15 emulator |
| Android QR pairing | Verified | Real phone to Linux, 2026-11-20 |
| Android arm64 phone | Verified | Nothing Phone 2, Android 16 |
| APK in-place upgrade | Verified | 20261120 to 20261121, same certificate, data intact; recorded 2026-11-20 |
| Linux app and keyring | Verified | Linux release app and keyring persistence |
| Linux device sync | Verified | Code entry, conflicts, deletions, and 476-note convergence |
| Sync collision and quarantine retry | Verified | Tested in CI; two-way sync on real devices |
| Tailscale | Unverified | Not tested |
| Linux package | Verified | `tool/package_linux.sh`; deterministic archive and checksum were checked previously |
| Android release signing guard | Verified | Release tasks fail without signing configuration |
| CI workflow | Verified | Runs on every push; passing |
| Public release | Not published | Only the `v1.0.0-preview.1` pre-release exists |
| In-app update checker | Verified on emulator | Real GitHub request reports no stable release; installer hand-off reaches Android's confirmation dialog; not yet end-to-end on a real device |
| Linux self-update | Blocked | Needs an owner-provisioned signing key; helper tested end to end with synthetic packages |

## Release candidate

Candidate stable version: `1.0.0+20261122` (Android versionCode `20261122`).
In a read-only check on 2026-11-21, the phone had `20261121` installed
(Android users 0 and 11); make a fresh read-only check before installing.
The preview build used `1`;
`.audit-input/known-codes.txt` was absent, so no other phone code was available
to check. The date-based code advances Android's update ordering with ample
headroom. Keep the Linux package version at `1.0.0`; it is derived from the
same `pubspec.yaml` version name.

## Verification record

| Date | Check | Result |
|---|---|---|
| 2026-11-20 | Automated suite | Over 1,200 tests pass; GitHub Actions green |
| 2026-11-20 | Real backup import | 44 notes, 0 failures; content not recorded |
| 2026-11-20 | Android export and restore | System save picker and content URI import; app JSON restore with preview, confirmation, snapshot, transaction |
| 2026-11-20 | Android emulator | x86_64, Android 15; emulator verification complete |
| 2026-11-20 | Linux sync | Code entry pairing, conflicts, deletions, 476-note convergence |
| 2026-11-20 | Release setup | Android release tasks blocked without signing configuration; CI passing |
