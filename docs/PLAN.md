# Plan

Status words: **verified** means supported by an automated test or a recorded
run; **unverified** means the check has not been done. Current verification
facts below were supplied by the integrator on 2026-11-20.

## Current position

The current suite reports 387 passed and 1 skipped; the skip reason was not
provided in the current verification report. A real backup import was
separately checked by counts only: 44 notes, 0 failures; no note content was
recorded.

Android export uses the system save picker (`ACTION_CREATE_DOCUMENT`), and
imports can read a content URI. Restoring Notes' own JSON export includes a
preview, confirmation, pre-restore database snapshot, and one transaction.
Sync collision handling and quarantine retry are implemented.

An Android x86_64 emulator running Android 15 and Linux sync were verified.
Linux sync paired by entering a code and covered conflicts and deletions, with
476-note convergence. Android QR scanning, arm64 phone use, and an in-place
APK upgrade remain unverified. Tailscale has not been checked. Release builds
now fail when Android signing configuration is absent. CI exists but has not
run. No release has been published; tag `v1.0.0-preview.1` has no assets.

## Next actions

1. Add the verified public signing-certificate fingerprint at
   `tool/release_cert_sha256.txt`; it is currently absent.
2. Complete Android and Linux release checks in [RELEASE.md](RELEASE.md).
3. Verify Android QR scanning, an arm64 phone, and an in-place APK update.
4. Run CI once and review its result.
5. Obtain written upstream permission with publication and distribution scope
   settled before any public release.

## Acceptance matrix

| Check | Status | Evidence or remaining gap |
|---|---|---|
| Automated tests | Verified | Integrator report: 387 passed, 1 skipped |
| Legacy backup import | Verified | Real backup: 44 notes, 0 failures; counts only |
| Notes JSON export and restore | Verified | Android system save picker; content URI import; restore preview, confirmation, snapshot, transaction |
| Android app launch and persistence | Verified | x86_64 Android 15 emulator |
| Android QR pairing | Unverified | Not tested |
| Android arm64 phone | Unverified | Not tested |
| APK in-place upgrade | Unverified | Not tested |
| Linux app and keyring | Verified | Linux release app and keyring persistence |
| Linux device sync | Verified | Code entry, conflicts, deletions, and 476-note convergence |
| Sync collision and quarantine retry | Implemented | Included in the current sync code; CI has not run |
| Tailscale | Unverified | Not tested |
| Linux package | Verified | `tool/package_linux.sh`; deterministic archive and checksum were checked previously |
| Android release signing guard | Verified | Release tasks fail without signing configuration |
| CI workflow | Unverified | Workflow is present; it has never run |
| Public release | Not published | `v1.0.0-preview.1` tag has no release assets |

## Release candidate

Candidate stable version: `1.0.0+20261121` (Android versionCode `20261121`).
The only known prior installed/distributed code is `1`, from the preview build;
`.audit-input/known-codes.txt` was absent, so no other phone code was available
to check. The date-based code advances Android's update ordering with ample
headroom. Keep the Linux package version at `1.0.0`; it is derived from the
same `pubspec.yaml` version name.

## Verification record

| Date | Check | Result |
|---|---|---|
| 2026-11-20 | Current automated suite | 387 passed, 1 skipped (integrator report) |
| 2026-11-20 | Real backup import | 44 notes, 0 failures; content not recorded |
| 2026-11-20 | Android export and restore | System save picker and content URI import; app JSON restore with preview, confirmation, snapshot, transaction |
| 2026-11-20 | Android emulator | x86_64, Android 15; emulator verification complete |
| 2026-11-20 | Linux sync | Code entry pairing, conflicts, deletions, 476-note convergence |
| 2026-11-20 | Release setup | Android release tasks blocked without signing configuration; CI not yet run |
