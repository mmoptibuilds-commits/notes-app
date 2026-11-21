#!/usr/bin/env bash
# Runs integration_test/android_tour_test.dart on an Android device or
# emulator and saves a real `adb screencap` for every ANDROID_TOUR_SHOT marker
# the test prints. Usage: tool/android_tour.sh <adb-serial> [out-dir]
# Use a disposable emulator: the test installs a build of Notes on it.
set -euo pipefail
SERIAL="${1:?adb serial, e.g. emulator-5554}"
OUT="${2:-build/screens/android}"
mkdir -p "$OUT"
LOG="$OUT/tour.log"
flutter test integration_test/android_tour_test.dart -d "$SERIAL" 2>&1 | tee "$LOG" |
while IFS= read -r line; do
  case "$line" in
    *ANDROID_TOUR_SHOT\ *)
      name="${line##*ANDROID_TOUR_SHOT }"; name="${name//[^A-Za-z0-9._-]/}"
      sleep 0.8
      adb -s "$SERIAL" exec-out screencap -p > "$OUT/$name.png"
      echo "captured $name" ;;
    *ANDROID_TOUR_FAILED_STEPS*|*"Some tests failed"*|*"All tests passed"*) echo "$line" ;;
  esac
done
