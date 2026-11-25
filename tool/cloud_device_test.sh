#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 || (${3:-scenario} != scenario && ${3:-scenario} != latency) ]]; then
  echo "Usage: $0 <android-serial> <worker-url> [scenario|latency]" >&2
  exit 2
fi

serial=$1
worker_url=$2
mode=${3:-scenario}
# `latency` measures automatic sync delay (tool/cloud_latency_report.dart).
if [[ $mode == latency ]]; then
  entry=integration_test/cloud_latency_test.dart
else
  entry=integration_test/cloud_device_test.dart
fi
export PATH="$HOME/development/flutter/bin:$PATH"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
export ORG_GRADLE_PROJECT_cloudTest=true

lock_path=${TMPDIR:-/tmp}/notes-cloud-device-test.lock
exec 9>"$lock_path"
if ! flock -n 9; then
  echo "Another cloud device test is already running." >&2
  exit 1
fi

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/notes-cloud-device-test.XXXXXX")
cleanup() { rm -rf -- "$temp_dir"; }
trap cleanup EXIT

apk=build/app/outputs/flutter-apk/app-debug.apk
aapt="$HOME/Android/Sdk/build-tools/36.0.0/aapt"
if [[ ! -x $aapt ]]; then
  echo "Missing aapt at the configured Android build-tools path." >&2
  exit 1
fi

echo "Building isolated cloud-test debug APK..."
abi=$(adb -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')
case $abi in
  arm64-v8a) platform=android-arm64 ;;
  x86_64) platform=android-x64 ;;
  *) echo "Unsupported device ABI: $abi" >&2; exit 1 ;;
esac
flutter build apk --debug --target "$entry" \
  --target-platform "$platform" \
  --dart-define=CLOUD_ROLE=A \
  --dart-define="NOTES_CLOUD_URL=$worker_url"
if [[ ! -f $apk ]]; then
  echo "Debug APK was not produced." >&2
  exit 1
fi

package=$($aapt dump badging "$apk" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
if [[ $package != com.mmoptibuilds.notes.cloudtest ]]; then
  echo "Refusing Android install: verified APK package id is not the cloud-test id." >&2
  exit 1
fi

# flutter drive installs this verified APK itself (-r, same package id).

echo "Resetting the test library..."
dart run tool/cloud_test_reset.dart "$worker_url"

offset_ms=0
if [[ $mode == latency ]]; then
  # Phone clock minus Linux clock, from the sample with the shortest round trip.
  best_rtt=-1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    t0=$(date +%s%N)
    remote=$(adb -s "$serial" shell date +%s%N | tr -d '\r')
    t1=$(date +%s%N)
    rtt=$((t1 - t0))
    if [[ $best_rtt -lt 0 || $rtt -lt $best_rtt ]]; then
      best_rtt=$rtt
      offset_ms=$(((remote - (t0 + t1) / 2) / 1000000))
    fi
  done
  echo "Phone clock offset: ${offset_ms} ms (best round trip $((best_rtt / 1000)) us)"
fi

set +e
flutter test "$entry" -d linux \
  --dart-define=CLOUD_ROLE=L \
  --dart-define="NOTES_CLOUD_URL=$worker_url" \
  >"$temp_dir/linux.log" 2>&1 &
linux_pid=$!
flutter drive -d "$serial" \
  --target "$entry" \
  --driver test_driver/integration_test.dart \
  --use-application-binary "$apk" \
  --dart-define=CLOUD_ROLE=A \
  --dart-define="NOTES_CLOUD_URL=$worker_url" \
  >"$temp_dir/android.log" 2>&1 &
android_pid=$!
wait "$linux_pid"
linux_status=$?
wait "$android_pid"
android_status=$?
set -e

echo "--- Linux log ---"
cat "$temp_dir/linux.log"
echo "--- Android log ---"
cat "$temp_dir/android.log"

step_from() {
  sed -n 's/.*FAIL scenario step=\([^[:space:]]*\).*/\1/p' "$1" | tail -n 1
}
report_side() {
  local name=$1 status=$2 log=$3 step
  step=$(step_from "$log")
  if [[ $status -eq 0 ]]; then
    echo "$name: PASS"
  else
    echo "$name: FAIL${step:+ (step: $step)}"
  fi
}

if [[ $mode == latency ]]; then
  echo "--- Latency report ---"
  dart run tool/cloud_latency_report.dart --offset-ms "$offset_ms" \
    "$temp_dir/linux.log" "$temp_dir/android.log" | tee "${CLOUD_LATENCY_REPORT:-/dev/null}"
fi

echo "--- Cloud device test summary ---"
report_side Linux "$linux_status" "$temp_dir/linux.log"
report_side Android "$android_status" "$temp_dir/android.log"

if [[ $linux_status -ne 0 || $android_status -ne 0 ]]; then
  exit 1
fi
