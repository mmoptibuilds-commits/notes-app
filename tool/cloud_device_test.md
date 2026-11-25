# Two-device cloud sync test

This test runs the same role-based scenario on Linux and the isolated Android
cloud-test application at the same time. Both use temporary encrypted Notes
databases, fake HTTP sign-in against the isolated test Worker, and real cloud
sync requests. Cross-process coordination uses short-lived `~barrier:` notes.

Run it with the Android device's wireless ADB serial and the test Worker URL:

```sh
tool/cloud_device_test.sh <android-serial> https://example.invalid
```

The script builds a debug APK with `ORG_GRADLE_PROJECT_cloudTest=true` and JDK
21, checks its package id is exactly `com.mmoptibuilds.notes.cloudtest`, then
lets `flutter drive` install only that APK (same package id, `-r`; the live
`com.mmoptibuilds.notes` app is never touched). The build ABI follows the device
(arm64 phone or x86_64 emulator). Before starting, `tool/cloud_test_reset.dart`
resets the test library so neither role can see a stale one. It starts Linux and
Android integration tests concurrently, stores both logs in a temporary
directory, and reports each side's result and failing scenario step. A lock
prevents overlapping runs. The test signs both devices out in `finally` so the
test Worker device limit is not consumed after a failure.

For local scenario debugging without devices, run both roles in one process:

```sh
CLOUD_LIVE_URL=https://example.invalid flutter test test/live/cloud_scenario_test.dart
```

The test proves real Worker upload/join, image transfer and SHA-256 integrity,
offline edits and merge behavior, Review edits conflicts, simultaneous clean
merges, retry after a committed push response is lost, deletion states,
metadata propagation and final record digest convergence. It does not exercise
the browser hop or Android deep link; those are verified separately. The test
Worker is reset by the script before both roles start, so do not run another
test against that deployment at the same time. The phone can start minutes after
Linux (a wireless-ADB install), so the first handshake waits up to 15 minutes;
offline edits wait 8 seconds before reconnecting so both sides edit before
either syncs.

## Empty-library setup through the UI

The v1.3.1 release check starts with an empty test library and drives the real
CloudScreen on Linux and Android, including verified backup, upload
confirmation, device check and join. The harness signs in both peers with its
test login before opening the screen. After joining, it verifies that each
peer's repository receives edits from the other through automatic cloud sync.
Run it only against the deployed test Worker; the script rejects URLs that do
not contain `notes-sync-test`:

```sh
tool/cloud_setup_ui_test.sh <android-serial> https://notes-sync-test.<worker-domain>
```

The script resets the test library and checks authenticated `GET /v1/library`
returns 404 before starting either role. It builds the isolated cloud-test APK
and runs Linux and Android together. Do not run another test against that test
Worker until the script finishes.
