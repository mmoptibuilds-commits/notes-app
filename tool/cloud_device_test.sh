#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <android-serial> <worker-url>" >&2
  exit 2
fi

serial=$1
worker_url=$2
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
flutter build apk --debug --target integration_test/cloud_device_test.dart \
  --target-platform android-arm64 \
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

driver="$temp_dir/cloud_device_driver.dart"
cat >"$driver" <<'DART'
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
DART

echo "Resetting the test library..."
dart run tool/cloud_test_reset.dart "$worker_url"

set +e
flutter test integration_test/cloud_device_test.dart -d linux \
  --dart-define=CLOUD_ROLE=L \
  --dart-define="NOTES_CLOUD_URL=$worker_url" \
  >"$temp_dir/linux.log" 2>&1 &
linux_pid=$!
flutter drive -d "$serial" \
  --target integration_test/cloud_device_test.dart \
  --driver "$driver" \
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

echo "--- Cloud device test summary ---"
report_side Linux "$linux_status" "$temp_dir/linux.log"
report_side Android "$android_status" "$temp_dir/android.log"

if [[ $linux_status -ne 0 || $android_status -ne 0 ]]; then
  exit 1
fi
