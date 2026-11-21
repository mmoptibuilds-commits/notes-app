# Development

## Toolchain

| Tool | Version | Notes |
|---|---|---|
| Flutter | 3.50.0 stable | CI pins the same version (`.github/workflows/ci.yml`). |
| JDK | 21 | JDK 17 makes the Android Gradle Plugin's lint crash. |
| Android SDK | platform 36, build-tools with `apksigner`/`aapt2` | Set `ANDROID_HOME` for `tool/verify_release_apk.dart`. |
| Linux build deps | GTK 3, `libsecret`, `clang`, `cmake`, `ninja`, `pkg-config` | Standard Flutter Linux desktop requirements. |
| Runtime tools | `openssl` 3+, `sha256sum` | Release verification; also used by tests. |

`flutter config` should point at the Android SDK and JDK 21. On the
maintainer's machine Flutter lives at `~/development/flutter/bin` and is not on
`PATH`; the checkout path contains a space, so quote paths in scripts.

## Commands

```bash
flutter pub get
dart format lib test tool
flutter analyze
flutter test                                  # everything (~1,300 tests, ~2 min)
flutter test test/sync                        # one area
flutter test --plain-name 'autosave'          # one test by name
flutter build linux --release
flutter build apk --release --target-platform android-arm64
tool/package_linux.sh                         # Linux release archive + .sha256
```

CI runs formatting, analysis, the full test suite and the release-configuration
checks on every push (`.github/workflows/ci.yml`). It never builds signed
artifacts and never holds signing keys.

## Running the app safely

- Linux: `NOTES_DATA_DIR=$(mktemp -d) build/linux/x64/release/bundle/notes`
  starts an isolated instance with its own database and a development key file
  instead of the system keyring. Use this for experiments and for a second
  device when testing sync on one machine.
- Synthetic datasets (empty, 50, 500 and a very large note) for manual or
  performance testing: see `docs/PERFORMANCE.md`.
- Android: use an emulator for experiments. Installing on a real phone with
  existing data must be an in-place update (`adb install -r`) signed with the
  release key; never uninstall or clear data.

## Signing setup (maintainer only)

- Android release builds read `android/key.properties`, a git-ignored link to
  the keystore configuration kept outside the repository. Without it a release
  build fails (by design: an APK signed with another key cannot update
  installed copies). The expected certificate is pinned in
  `tool/release_cert_sha256.txt`.
- The update-manifest key (`notes-release-1`) is never needed for building;
  only for signing a release manifest (`docs/RELEASE.md`).

## Tests

- `test/` mirrors `lib/`. Shared helpers: `test/support/` (fonts, window size,
  screenshots), `test/ui/library/support.dart` (`seedLibrary()` synthetic
  library), `test/fixtures/`.
- Widget tests set the window with `setWindow(tester, Size(...))`. Test phone
  (412x915) and desktop (1280x800 and larger) widths for any layout change.
- Every schema migration has an upgrade test; every bug fix gets a regression
  test that fails without the fix.
- Tests touching the filesystem use temporary directories; perf and sync tests
  set `NOTES_DATA_DIR` to a temp dir.
- The Linux desktop smoke test launches the real GTK app and uses a temporary
  encrypted database. Run it on a desktop session with:

  ```bash
  flutter test integration_test/desktop_smoke_test.dart -d linux
  ```

  This test exercises the native engine and disk persistence; it is separate
  from the headless widget tests.

## Visual review

Widget tests can write PNGs of real rendered screens (real fonts, synthetic
data) to `build/screens/` via `screenshot()` in `test/support/screenshot.dart`.
`test/visual/review_screens_test.dart` renders the main screens at phone and
desktop sizes:

```bash
flutter test test/visual/review_screens_test.dart && ls build/screens/
```

For a real Android rendering pass (device insets, system fonts and density),
run the screen tour on the Android 15 x86_64 emulator:

```bash
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/android_tour_test.dart -d emulator-5554 --profile
```

The tour creates a fresh temporary database, seeds synthetic notes, and removes
the database when it finishes. PNGs are written to
`build/screens/android/<name>.png`. The test prints captured names and logs
individual step failures while continuing through the remaining tour. Review
the screenshots after the run; `flutter drive` installs its test build on the
emulator, and the tour never uses a real data directory.

Look at the images after any UI change; they are review artefacts, not golden
tests. Also check: the three themes (AMOLED, charcoal, light), text scale 1.4,
keyboard focus order and Escape layering, and that Android touch targets stay
at least 48 dp.

## Icons and brand

The icon and launch glyph are drawn in code (`lib/ui/brand_mark.dart`).
`flutter test tool/generate_icons.dart` regenerates every icon PNG; commit the
output. The splash (`lib/ui/splash.dart`) and the Android launch screens use
the same glyph and colours.
