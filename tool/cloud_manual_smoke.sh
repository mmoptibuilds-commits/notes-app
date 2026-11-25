#!/usr/bin/env bash
# Manual mobile-data smoke test for cloud sync (see tool/cloud_manual_smoke.md).
#   tool/cloud_manual_smoke.sh setup <adb-serial> <test-worker-url>
#   tool/cloud_manual_smoke.sh run   <adb-serial> <test-worker-url>
# `setup` installs the isolated "Notes (cloud test)" app on the phone (fresh,
# synthetic, test Worker only). `run` resets the test library and runs the Linux
# half; it needs no ADB once started, so the phone can switch to mobile data.
set -euo pipefail

if [[ $# -ne 3 || ($1 != setup && $1 != run) ]]; then
  echo "Usage: $0 setup|run <android-serial> <test-worker-url>" >&2
  exit 2
fi
mode=$1 serial=$2 worker_url=$3
case $worker_url in
  *notes-sync-test*) ;;
  *) echo "Refusing: the URL must be the isolated test Worker." >&2; exit 2 ;;
esac
export PATH="$HOME/development/flutter/bin:$PATH"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
export ORG_GRADLE_PROJECT_cloudTest=true
test_package=com.mmoptibuilds.notes.cloudtest

if [[ $mode == setup ]]; then
  abi=$(adb -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')
  case $abi in
    arm64-v8a) platform=android-arm64 ;;
    x86_64) platform=android-x64 ;;
    *) echo "Unsupported device ABI: $abi" >&2; exit 1 ;;
  esac
  flutter build apk --debug --target-platform "$platform" \
    --dart-define="NOTES_CLOUD_URL=$worker_url"
  apk=build/app/outputs/flutter-apk/app-debug.apk
  aapt="$HOME/Android/Sdk/build-tools/36.0.0/aapt"
  package=$($aapt dump badging "$apk" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
  if [[ $package != "$test_package" ]]; then
    echo "Refusing: the APK package id is not the cloud-test id." >&2
    exit 1
  fi
  # Only the isolated test package is removed, for a clean empty library.
  adb -s "$serial" uninstall "$test_package" >/dev/null 2>&1 || true
  adb -s "$serial" install "$apk"
  echo "Installed $test_package (Notes (cloud test)). The live app was not touched."
  exit 0
fi

phone_ip=$(adb -s "$serial" shell ip -o -4 addr show wlan0 2>/dev/null |
  sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1)
echo "Phone LAN address (for the mobile-data check): ${phone_ip:-unknown}"
echo "Resetting the test library..."
dart run tool/cloud_test_reset.dart "$worker_url"
echo "Starting the Linux half. Follow tool/cloud_manual_smoke.md on the phone."
flutter test integration_test/cloud_manual_smoke_test.dart -d linux \
  --dart-define="NOTES_CLOUD_URL=$worker_url" \
  --dart-define="PHONE_LAN_IP=$phone_ip" 2>&1 | grep --line-buffered -E "SMOKE|All tests|Some tests|Bad state|Timed out"
