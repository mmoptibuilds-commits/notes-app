#!/bin/sh
# Launch an already-installed app on an explicitly selected emulator.
# Usage: tool/perf/android_startup.sh <adb-serial> <package-id> [--allow-physical]
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <adb-serial> <package-id> [--allow-physical]" >&2
  exit 2
fi
serial=$1
package=$2
allow_physical=${3:-}
[ -n "$serial" ] || { echo 'An explicit adb serial/transport is required.' >&2; exit 2; }
if [ "$package" = 'com.saadhjawwadh.notebook' ]; then
  echo 'Refusing to inspect the protected Notes app package.' >&2
  exit 1
fi
if [ -n "$allow_physical" ] && [ "$allow_physical" != '--allow-physical' ]; then
  echo "Unknown option: $allow_physical" >&2
  exit 2
fi
command -v adb >/dev/null 2>&1 || { echo 'adb is required.' >&2; exit 1; }

state=$(adb -s "$serial" get-state 2>/dev/null || true)
[ "$state" = 'device' ] || { echo "adb target is unavailable: $serial" >&2; exit 1; }
if [ "$allow_physical" != '--allow-physical' ]; then
  is_emulator=$(adb -s "$serial" shell getprop ro.kernel.qemu | tr -d '\r')
  model=$(adb -s "$serial" shell getprop ro.product.model | tr -d '\r')
  case "$is_emulator:$model" in
    1:*|*:sdk_gphone*|*:Android_SDK_built_for*) ;;
    *) echo "Target $serial is not identified as an emulator. Pass --allow-physical to opt in." >&2; exit 1 ;;
  esac
fi

# Never clear app data; this script only launches and reads Android diagnostics.
launch=$(adb -s "$serial" shell am start -W \
  -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER \
  -p "$package" 2>&1) || {
  printf '%s\n' "$launch" >&2
  exit 1
}
printf '%s\n' "$launch" | awk -F: '/^(ThisTime|TotalTime|WaitTime):/ {gsub(/[[:space:]]/, "", $1); gsub(/[[:space:]]/, "", $2); print $1 "=" $2 "ms"}'

mem=$(adb -s "$serial" shell dumpsys meminfo "$package" 2>&1)
pss=$(printf '%s\n' "$mem" | awk '/^[[:space:]]*TOTAL[[:space:]]/ {print $2; found=1} END {if (!found) print "unavailable"}')
gfx=$(adb -s "$serial" shell dumpsys gfxinfo "$package" 2>&1)
frames=$(printf '%s\n' "$gfx" | awk -F: '/Total frames rendered:/ {gsub(/[[:space:]]/, "", $2); total=$2} /Janky frames:/ {gsub(/[[:space:]]/, "", $2); janky=$2} END {if (total == "") total="unavailable"; if (janky == "") janky="unavailable"; print total "/" janky}')
printf 'Serial\tPackage\tPSS MiB\tFrames/Janky\n'
case "$pss" in
  *[!0-9]*|'') pss_mib=$pss ;;
  *) pss_mib=$((pss / 1024)) ;;
esac
printf '%s\t%s\t%s\t%s\n' "$serial" "$package" "$pss_mib" "$frames"
