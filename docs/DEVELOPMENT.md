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
flutter test                                  # the full suite; takes several minutes
flutter test test/sync                        # one area
flutter test --plain-name 'autosave'          # one test by name
flutter build linux --release
flutter build apk --release --target-platform android-arm64
tool/package_linux.sh                         # Linux release archive + .sha256
```

The production build contains the public default cloud server address, so it
needs no `NOTES_CLOUD_URL` define. To build and test the Worker:

```bash
cd server/sync
npm ci
npm run typecheck
npm test
npm run build
```

Use only the isolated test Worker for a live client check:

```bash
cd ../..                                  # return to the repository root
CLOUD_LIVE_URL=https://<test worker> flutter test test/live/cloud_live_test.dart
```

The Android cloud test build requires an explicit test Worker URL and uses a
separate application id (`com.mmoptibuilds.notes.cloudtest`); it cannot access
the production app's private data:

```bash
cd ../..                                  # return to the repository root
tool/build_cloudtest_apk.sh --dart-define=NOTES_CLOUD_URL=https://<test worker>
```

Two-device test (Linux plus an Android device or emulator, isolated
`com.mmoptibuilds.notes.cloudtest` app id, test Worker only):

```bash
tool/cloud_device_test.sh <adb-serial> https://<test-worker-url>
```

Details, scope and limits: `tool/cloud_device_test.md`. For a single-process run
of the same scenario: `CLOUD_LIVE_URL=<test-worker-url> flutter test test/live/cloud_scenario_test.dart`.

`tool/build_cloudtest_apk.sh` writes `build/app/outputs/flutter-apk/app-release.apk`,
the same path as the release build: build the real release APK last.

Automatic sync timing (synthetic notes, no taps on Sync now): two roles pass
notes back and forth and the report prints, per case, how long a note takes to
appear on the other device.

```bash
CLOUD_LATENCY_REPORT=/tmp/latency.txt \
  tool/cloud_device_test.sh <adb-serial> https://<test-worker-url> latency
# without a phone: both roles in one process
CLOUD_LIVE_URL=<test-worker-url> flutter test test/live/cloud_latency_test.dart
```

It covers a plain save, a save pushed at once (poll only), resume, a save
followed by backgrounding, and reconnecting after 100 s offline (a local proxy
drops the connection), then counts the requests each device sends while idle.
Cross-device times are corrected for the phone/Linux clock offset measured over
ADB. The isolated test Worker is reset first, so run nothing else against it.

Measured 2026-11-25 against the test Worker, with Linux paired with the Android
emulator and with a physical Android phone on Wi-Fi (seconds from saving on one
device to seeing it on the other, no Sync now; both directions pooled):

| Case | Emulator before | Emulator after | Phone before | Phone after |
|---|---|---|---|---|
| Plain save | 22 to 49 | 2.6 to 11.5 | 22 to 68 | 4.5 to 11.0 |
| Save pushed at once (poll only) | 7 to 14 | 2.4 to 7.6 | 3 to 27 | 0.5 to 9.0 |
| Save, then app sent to the background | 52 to 70 | 2.6 to 14.5 | 59 to 71 | 1.5 to 2.9 |
| Reconnect after 100 s offline | 72 to 84 | 11.5 to 14.5 | 73 to 83 | 11.1 to 14.9 |
| Resume | 0.1 | 0.2 | 0.4 to 0.5 | 0.4 to 0.5 |
| Idle head requests per 90 s | 3 | 9 | 3 | 9 |

"Before" is the 1.2.x timing (20 s save delay, 30 s poll, Android dropped waiting
edits when paused). Phone runs have two to three samples per case, so treat the
ranges as indicative.

The cost is one head request every 10 s while a window is visible, about 8,640 a
day per device, against the Workers Free limit of 100,000 a day; polls do not
touch Neon.

Mobile-data smoke test (phone on mobile data, Linux on Wi-Fi, no ADB while it
runs): `tool/cloud_manual_smoke.sh setup|run` and `tool/cloud_manual_smoke.md`.

For a Linux development instance, set both its data directory and explicit
test endpoint. With no explicit endpoint, a `NOTES_DATA_DIR` instance has no
cloud configured and never falls back to the production server:

```bash
mkdir -p /tmp/notes-dev
NOTES_DATA_DIR=/tmp/notes-dev NOTES_CLOUD_URL=https://<test worker> notes
```

Development sessions stay in that instance's plain-text `cloud-session.json`
file. Treat it as a credential, remove it with the disposable instance, and do
not commit it. Do not point development instances or live tests at the
production cloud library.

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
- The live cloud test is opt-in through `CLOUD_LIVE_URL` and must use the test
  Worker and its isolated Neon project. Cloud tests otherwise use synthetic
  in-memory servers.
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
tool/android_tour.sh emulator-5554
```

The tour creates a fresh temporary database, seeds synthetic notes, and removes
the database when it finishes. At each step the test prints an
`ANDROID_TOUR_SHOT <name>` marker and holds still; the script takes an
`adb screencap` (real system bars and fonts) into
`build/screens/android/<name>.png`, with the full log in `tour.log` there. (The
integration_test screenshot API hung on the emulator, so it is not used.) A
failing step is logged and the tour continues, then the test fails at the end
listing every failed step. The test build is installed on the emulator; use a
disposable emulator, never the owner's phone. The tour never uses a real data
directory.

Look at the images after any UI change; they are review artefacts, not golden
tests. Also check: the three themes (AMOLED, charcoal, light), text scale 1.4,
keyboard focus order and Escape layering, and that Android touch targets stay
at least 48 dp.

For settings accessibility changes, check system text scale 2.0 on both Settings
and Toolbar settings. Segmented choices should wrap labels or fall back to a
choice menu when a label cannot fit. Dialog actions and move-to-folder rows
should remain at least 48 dp on Android. The editor toolbar's edge fades should
show when controls continue offscreen without changing the bar's size, and
their transitions should follow the reduced-motion setting.

For a broader state-by-state atlas, run:

```bash
flutter test test/visual/atlas_test.dart
```

The PNGs are written under `build/screens/atlas/<form>/<theme>/`; the generated
`build/screens/atlas/INDEX.md` describes each captured state. The atlas uses
in-memory synthetic notes and includes the full view layer so pushed routes,
menus and dialogs remain visible. Android-only camera scanning and native OS
dialogs cannot be rendered on the Linux test host.

## Icons and brand

The icon and launch glyph are drawn in code (`lib/ui/brand_mark.dart`).
`flutter test tool/generate_icons.dart` regenerates every icon PNG; commit the
output. The splash (`lib/ui/splash.dart`) and the Android launch screens use
the same glyph and colours.
