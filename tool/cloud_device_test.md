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
installs only that APK with `adb install -r -s <serial>`. It starts Linux and
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
Worker is reset by the Linux role, so do not run another test against that
deployment at the same time.
