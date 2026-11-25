# Stable release procedure

Source release version: `1.3.0+20261126` (versionName `1.3.0`, Android
versionCode `20261126`). The previous distributed stable release is
`1.2.0+20261125`, published 2026-11-24. The latest recorded read-only phone check, on
2026-11-21, found versionCode `20261122`; check installed versionCodes
read-only again before installing, including on other target devices. Treat
that phone value as a dated snapshot, not a permanent current value. The
`tool/last_release_version_code.txt` holds the build number of the last
distributed stable release (`20261125`, Notes 1.2.0, published 2026-11-24).
Update it in the commit that follows each published release.

## 1. Preflight

Use Flutter 3.50.0 stable and JDK 21. From the repository root:

```sh
export PATH="$HOME/development/flutter/bin:$PATH"
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
flutter --version
java -version
flutter doctor -v
flutter pub get
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
```

Confirm the working tree contains the intended release changes. Review the
release notes, the [third-party notice gaps](THIRD_PARTY_LICENSES.md), and
upstream permission scope before distributing anything.

## 2. Set the version

The preceding release was `1.2.0+20261125`; this source tree sets
`1.3.0+20261126`. Before changing the version for a later release, make a fresh
read-only check of installed phone versionCodes. Change only the `version:`
line, then run:

```sh
sed -i 's/^version: .*/version: <version>+<build>/' pubspec.yaml
dart tool/check_stable_version.dart --stable
```

The check compares the build number to
`tool/last_release_version_code.txt` (or an explicit `--previous` value). The
APK's `versionCode` is its Android update ordering; it must be greater than
every code already installed. The Linux archive version is derived from the
same version line, so keep the version name consistent.

## 3. Check signing configuration

The existing update-compatible Android signing key must be available through
`android/key.properties`, with nonblank `storeFile`, `storePassword`,
`keyAlias`, and `keyPassword`, and an existing keystore at `storeFile`. The
Gradle task-graph guard blocks release packaging if those values or the file
are missing. Do not print, paste, commit, or inspect the properties or
keystore contents. Do not generate a replacement key for an update release.

Before verification, confirm that `tool/release_cert_sha256.txt` contains the
expected **public** SHA-256 fingerprint from a trusted record of the existing
release certificate. Do not learn the expected value from the APK being
verified; that would not check continuity with the installed app.

## 4. Build and verify Android

```sh
flutter build apk --release --target-platform android-arm64
dart tool/verify_release_apk.dart build/app/outputs/flutter-apk/app-release.apk
apkanalyzer manifest version-code build/app/outputs/flutter-apk/app-release.apk
```

The verifier calls Android SDK `apksigner verify --print-certs`, rejects a
debug certificate, and checks the result against
`tool/release_cert_sha256.txt`. It finds `apksigner` under the SDK named by
`ANDROID_SDK_ROOT` or `ANDROID_HOME`. Confirm `apkanalyzer` reports
the new build number (e.g. `20261125` for 1.2.0) and the APK reports the expected package id,
`com.mmoptibuilds.notes`.

## 5. Package Linux and verify checksums

With Flutter still on `PATH`:

```sh
tool/package_linux.sh
(cd dist && sha256sum -c notes-<version>-linux-x64.tar.gz.sha256)
```

The script builds `flutter build linux --release`, creates
`dist/notes-<version>-linux-x64.tar.gz` with the application bundle, installer,
uninstaller, update helper, desktop entry, icon, and four font OFL texts, then
writes a SHA-256 sidecar. The sidecar names the bare file, so the checksum runs inside `dist/`.

## 6. Stable update manifest and assets

The release assets are named `notes-<ver>-linux-x64.tar.gz` and
`notes-<ver>-android-arm64.apk`, alongside `notes-manifest.json` and
`notes-manifest.json.sig`. Build the canonical manifest from the finished
artifacts, including the Android versionCode and the independently recorded
release-certificate SHA-256 fingerprint:

```sh
dart tool/release/make_manifest.dart --version <version> --build-number <build> \
  --published-at <UTC time> --expires <UTC time> \
  --linux dist/notes-<version>-linux-x64.tar.gz \
  --android dist/notes-<version>-android-arm64.apk --version-code <build> \
  --cert-sha256 <trusted-certificate-sha256> --out-dir dist
dart tool/release/sign_manifest.dart --key "$W/private.json" \
  --key-id notes-release-1 --manifest dist/notes-manifest.json \
  --sig dist/notes-manifest.json.sig
dart tool/release/verify_manifest.dart --pubkeys tool/release_signing_pubkeys.json \
  --artifact dist/notes-<version>-linux-x64.tar.gz \
  --artifact dist/notes-<version>-android-arm64.apk \
  dist/notes-manifest.json dist/notes-manifest.json.sig
```

The signed manifest covers the exact generated bytes. Signing is done only by
the owner on their own machine; CI must never hold the private key. The
production key `notes-release-1` (DER SPKI SHA-256
`6947c0cb0e4311f7579a37d028f5b5e013326f93935b2b918cacfbd7a0ed0471`) is pinned
since 2026-11-21; its encrypted backups (local + Google Drive, neither offline)
are described in [UPDATES.md](UPDATES.md). Build the release artifacts only
from a commit that contains the pinned key, and sign the manifest for exactly
those files.

When decrypting the encrypted key on the offline signing machine, use
`umask 077; W=$(mktemp -d /dev/shm/notes-release-key-XXXXXX); gpg --no-symkey-cache --output "$W/private.json" --decrypt <backup>/notes-release-1.private.json.gpg`
(`<backup>` is the local backup directory or a fresh download of the Drive copy)
(RAM-backed `/dev/shm`; run `ulimit -c 0` first and `rm -rf "$W"` when done).

Expected assets are `notes-<version>-android-arm64.apk`,
`notes-<version>-linux-x64.tar.gz`,
`notes-<version>-linux-x64.tar.gz.sha256`, `notes-manifest.json`, and
`notes-manifest.json.sig`. Orion Store reads `/releases/latest` (stable,
non-prerelease) and treats every asset name containing `apk` as a download
candidate, using the first. Include exactly one such asset:
`notes-<version>-android-arm64.apk`. Never upload an APK checksum sidecar or
other asset whose name contains `apk`.

## 7. User release actions

Before publication, review the provenance and permission records, confirm the
expected certificate fingerprint and installed versionCodes, and review the
font and open-source notices. The app
has an in-app licences page at Settings > Open-source licences, the APK bundles
the four font licence text files, and the Linux archive ships OFL texts beside
the fonts. Orion's listing icon and screenshots load from
`android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` and
`docs/screenshots/*.png` in the release commit; keep these paths available to
the listing. Check that CI passed for the exact release commit. After review,
the owner decides whether to create a tag, publish assets, or distribute the
Linux archive. This procedure does not publish or push anything.

## Cloud server

Before releasing a client that depends on a new cloud schema or endpoint,
deploy the matching production Worker bundle and apply every required
`server/sync/migrations/` migration to the production Neon database. Apply Neon
migrations separately with the migration script; deploying a Worker does not
run them. The production client uses the default server address compiled in
`lib/sync/cloud/cloud_config.dart`, so no URL define is needed. Never use the
test Worker or test Neon project as the production release target.

To roll back Worker code, redeploy the previous production bundle and its
matching public configuration through the Cloudflare API or Wrangler. The SQL
migrations are append-only; do not try to reverse them as part of a Worker
rollback. Confirm that the older bundle remains compatible with the migrated
schema before restoring it.

To rotate `SESSION_SECRET`, replace the Worker secret through the Cloudflare
secret-management interface or API. The change invalidates access tokens,
refresh tokens and pending authorization state, so devices must sign in again.
Device rows remain active in Neon, however, and still count toward the five
device limit. After rotating the secret, revoke all old rows in the Neon SQL
console before devices sign in again:

```sql
UPDATE devices SET revoked_at = now() WHERE revoked_at IS NULL;
```

Never put the secret in a vars file, source tree, build bundle, command log or
release artifact.

To change the owner account, set `OWNER_SUB` to the new Google account's
verified subject using the Cloudflare secret-management interface. The Worker
does not expose the subject after successful sign-in. To obtain the new
account's subject, the operator can use the sign-in setup mode with
`OWNER_SUB` unset; the callback then displays the verified account ID to that
user and issues no device token. Set `OWNER_SUB` immediately afterward.
Existing device sessions are not bound to that setting after sign-in, so revoke
old device rows using the SQL above before the new owner signs in. Keep the
Google consent screen's test-user list current while it is in Testing mode. No
Worker, Neon or Google secret may be committed.

## Upgrading and rolling back (1.3.0)

Users install 1.3.0 from the published GitHub release: the in-app updater on
Linux (signed manifest) or the APK on Android, as an in-place update signed with
the same certificate as the installed build. Never uninstall or clear the
installed app to get past a signing mismatch. No private install is needed
before publishing; the release is checked with the isolated test app
(`com.mmoptibuilds.notes.cloudtest`), the test Worker and synthetic notes only.

Android's versionCode must be higher than the installed one (1.3.0 is
20261126, 1.2.0 is 20261125), or the system refuses the update.

**Before upgrading a device**, in the 1.2.0 app open Data, export a Notes JSON
backup, check that the export finishes, and copy it off the device. On Linux,
with Notes closed, also copy the data directory:
`cp -a ~/.local/share/com.mmoptibuilds.notes ~/Backups/notes-data-pre-1.3.0`.
Keep the 1.2.0 assets (`notes-1.2.0-android-arm64.apk`,
`notes-1.2.0-linux-x64.tar.gz`, its `.sha256`, the manifest and its signature)
from the `v1.2.0` GitHub release.

The first start of 1.3.0 migrates the local database to schema 4 and writes
`notes.db.pre-v4.bak`, a copy of the database as it was before. 1.2.0 devices
and 1.3.0 devices keep syncing over the LAN. Cloud sync stays off until the
owner signs in and confirms the one-time library upload (Linux uploads after a
verified backup, then Android joins).

**To roll back**, first turn cloud sync off and sign out on every device, then:

- Linux: close Notes. A 1.2.0 build refuses the migrated database. Extract the
  1.2.0 archive, check its SHA-256, run its `install.sh`, move `notes.db`,
  `notes.db-wal` and `notes.db-shm` aside and copy `notes.db.pre-v4.bak` to
  `notes.db` (the key stays in the keyring). Edits made after the upgrade are
  not in that copy: export them from 1.3.0 first and restore them with Data,
  Restore, or restore the directory copy made before the upgrade.
- Android: the system refuses to install build 20261125 over 20261126, and the
  `.pre-v4.bak` copy is in app-private storage that cannot be reached without
  root. Save a verified export from 1.3.0 off the device, uninstall Notes (this
  deletes its data), install the 1.2.0 APK, then restore the export with Data,
  Restore. Do this only with a verified export in hand.
- Cloud library: it stays in Neon and does no harm unused. To discard it, run
  `SELECT sync_reset();` in the Neon SQL console as the project owner (the app
  role cannot run it), then revoke device rows with the SQL in the Cloud server
  section. Worker code rolls back as described there.

### Checking automatic sync

After a change to `lib/sync/cloud/`, measure it with synthetic notes only (see
the latency test in [DEVELOPMENT.md](DEVELOPMENT.md)). Expected behaviour while
two devices are open: a save appears on the other device within about 15
seconds (measured 2.6 to 11.5 s on an emulator, 4.5 to 11.0 s on a phone), an
edit made while offline is pushed within one poll after the network returns, and
a paused Android app pushes waiting edits before it stops.

## CI review

`.github/workflows/ci.yml` requests only `contents: read`. It uses Java 21 and
Flutter 3.50.0 stable. No signing secrets are configured or needed:
release-configuration tests exercise validation helpers and the Gradle release
guard without building a signed release. The workflow runs formatting,
analysis and tests on pushes; check the run for the exact release commit before
distributing. Actions are pinned to full commit SHAs (with the version in a
comment).

<!-- BEGIN MANUAL RELEASE SMOKE -->
## Manual Android and Linux release-build checks

The dispatch workflow must exist on the repository's default branch before it
can be run. To check the workflow on `main`:

```sh
gh workflow run release-smoke.yml --ref main
gh run watch <run-id> --exit-status
```

The Android job builds the arm64 release APK, signs it with a freshly generated
temporary CI certificate, and checks its signature, app id, version name and
code, and arm64 library contents. The Linux job builds the release package and
checks its executable, bundled libraries, installer, uninstaller, update
helper, desktop entry, icon, four font OFL texts, `BUILD` file and SHA-256
sidecar. The workflow requests read-only repository contents and uploads no
build artifacts.

These checks prove that both release build paths and their package contents
work for the dispatched commit. The Android certificate exists only for that
CI run and is not the production release key. This is not a release: the APK
is not signed for updates and cannot be installed over a production Notes
installation. The checks do not publish artifacts or validate production
signing continuity, manifest signing, or installation on a device.

### Protection of main

Applied 2026-11-24 as the repository ruleset "Protect main: no deletion, no
force push" (id 27974079): enforcement active, target `refs/heads/main` only,
no bypass actors, rules `deletion` and `non_fast_forward`. Ordinary authorized
fast-forward pushes still work; there is no pull-request, review, status-check
or update restriction. Other branches and tags are not affected.

To change it, open **Settings → Rules → Rulesets** in the GitHub repository (or
use `gh api repos/mmoptibuilds-commits/notes-app/rulesets`), edit or delete
that ruleset, or set it to Disabled. Read the effective rules with
`gh api repos/mmoptibuilds-commits/notes-app/rules/branches/main`.
<!-- END MANUAL RELEASE SMOKE -->
