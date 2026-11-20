# Stable release procedure

Candidate version: `1.0.0+20261122` (versionName `1.0.0`, Android
versionCode `20261122`; the owner's phone has the earlier candidate
`20261120` installed, so this is the first code that updates it in place; the phone later received 20261121 (a different build), so the next candidate is 20261122). The current previous-code file contains `1`, the
preview code. No `.audit-input/known-codes.txt` was available; check any
additional installed versionCode before release. `tool/last_release_version_code.txt`
must remain the previous distributed code until the next release cycle.

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

Change only the `version:` line in `pubspec.yaml` to the candidate version:

```sh
sed -i 's/^version: .*/version: 1.0.0+20261122/' pubspec.yaml
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

Before verification, place the expected **public** SHA-256 certificate
fingerprint from a trusted record of the existing release certificate in
`tool/release_cert_sha256.txt`. It records the certificate of the preview and the preview APK installed on the owner device (SHA-256 3a1730a6…c8ca1), taken from a prior release-signed APK and confirmed by the integrator against the installed app. Do not learn the
expected value from the APK being verified; that would not check continuity
with the installed app.

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
`20261122` and the APK reports the expected package id,
`com.mmoptibuilds.notes`.

## 5. Package Linux and verify checksums

With Flutter still on `PATH`:

```sh
tool/package_linux.sh
sha256sum -c dist/notes-1.0.0-linux-x64.tar.gz.sha256
```

The script builds `flutter build linux --release`, creates
`dist/notes-1.0.0-linux-x64.tar.gz` with the application bundle, installer,
uninstaller, desktop entry, icon, and four font OFL texts, then writes a
SHA-256 sidecar. The checksum command verifies that sidecar from the
repository root.

## 6. User release actions

Before any distribution, the user must provide written upstream permission
with its publication and distribution scope settled, confirm the expected
certificate fingerprint and any installed versionCodes, and arrange a
user-viewable Android font notice. The current app has no in-app licences page
and the APK does not include the separate font licence text files. CI has not
run; review its first result before release. After the release is reviewed,
the user decides whether to create a tag, publish assets, or distribute the
Linux archive. This procedure does not publish or push anything.

## CI review

`.github/workflows/ci.yml` is structurally valid and requests only
`contents: read`. It uses Java 21 and Flutter 3.50.0 stable, matching the
project toolchain. No signing secrets are configured or needed: release
configuration tests exercise validation helpers and the Gradle release guard
without building a signed release. The workflow runs formatting, analysis,
and tests; caching is not configured. The actions use version tags
(`actions/checkout@v4`, `actions/setup-java@v4`, and
`subosito/flutter-action@v2`), not full commit SHAs. This worker could not
verify SHAs offline; verify the intended upstream action commits and pin by
full SHA in a separate reviewed change. The workflow exists but has never
run.
