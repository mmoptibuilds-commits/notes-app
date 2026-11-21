---
name: notes-release
description: Build and verify a Notes release candidate (signed arm64 APK and Linux archive) without publishing or installing on the phone. Use when preparing or checking a release.
---

# Notes release candidate

Follow `docs/RELEASE.md`; the executable checklist is:

1. Clean tree on the intended commit; `git rev-parse HEAD` recorded.
2. Read installed versionCodes read-only before choosing a build number. The latest recorded phone snapshot, checked on 2026-11-21, is `20261122`; check it again before installing and never treat that value as permanent. This release candidate is `1.0.0+20261123`; run `dart tool/check_stable_version.dart --stable` and confirm the code exceeds every installed code. Keep `tool/last_release_version_code.txt` at the previous distributed code until distribution.
3. Gates: `dart format --output=none --set-exit-if-changed lib test tool`, `flutter analyze`, `flutter test`.
4. Android: `flutter build apk --release --target-platform android-arm64` (JDK 21; `android/key.properties` symlink must exist; never read or print it). Then `dart tool/verify_release_apk.dart build/app/outputs/flutter-apk/app-release.apk`; confirm applicationId `com.mmoptibuilds.notes`, versionCode, certificate SHA-256 against `tool/release_cert_sha256.txt`, only the expected permissions, `allowBackup=false`.
5. Linux: `tool/package_linux.sh`, then `sha256sum -c dist/notes-<ver>-linux-x64.tar.gz.sha256`.
   Build all artifacts again after the production manifest key is pinned.
   Orion Store reads GitHub `/releases/latest` (stable, non-prerelease) and
   treats every asset name containing `apk` as a download candidate, using the
   first. Upload exactly one: `notes-<version>-android-arm64.apk`. Never upload
   an `.apk.sha256` sidecar or any other asset whose name contains `apk`.
6. Install on the disposable emulator only. Never install on the physical phone, clear app data, or touch `com.saadhjawwadh.notebook` without the owner's explicit approval.
7. Record APK and archive SHA-256 next to the exact commit. Do not tag, publish, push to main or merge without explicit owner approval.
