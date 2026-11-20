#!/bin/sh
# Measure Linux release startup and idle resource use against a synthetic DB.
# Usage: tool/perf/linux_startup.sh <bundle-notes-binary> <seeded-data-dir> [idle-seconds]
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <bundle-notes-binary> <seeded-data-dir> [idle-seconds]" >&2
  exit 2
fi
binary=$1
data_dir=$2
idle_seconds=${3:-5}
case "$idle_seconds" in *[!0-9]*|'') echo 'idle-seconds must be a positive integer' >&2; exit 2 ;; esac
[ "$idle_seconds" -gt 0 ] || { echo 'idle-seconds must be positive' >&2; exit 2; }
[ "$idle_seconds" -le 300 ] || { echo 'idle-seconds is capped at 300.' >&2; exit 2; }
[ -x "$binary" ] || { echo "Release binary is missing or not executable: $binary" >&2; exit 1; }
[ -f "$data_dir/500/notes.db" ] || { echo 'Expected seeded synthetic DB at <data-dir>/500/notes.db' >&2; exit 1; }

resolved_data=$(cd "$data_dir" && pwd -P)
temp_root=$(cd "${TMPDIR:-/tmp}" && pwd -P)
case "$resolved_data" in
  "$temp_root"/*) ;;
  *) echo 'Seeded data directory must be under the system temp directory.' >&2; exit 1 ;;
esac
configured_data=${NOTES_DATA_DIR:-}
effective_data="$resolved_data/500"
if [ -n "$configured_data" ]; then
  configured_data=$(cd "$configured_data" 2>/dev/null && pwd -P || true)
  if [ -n "$configured_data" ] && [ "$effective_data" = "$configured_data" ]; then
    echo 'Refusing to run against the configured application data directory.' >&2
    exit 1
  fi
fi

if ! command -v getconf >/dev/null 2>&1; then
  echo 'getconf is required to interpret /proc CPU ticks.' >&2
  exit 1
fi
hz=$(getconf CLK_TCK)
start_ns=$(date +%s%N)
NOTES_DATA_DIR="$effective_data" "$binary" >/dev/null 2>&1 &
pid=$!
cleanup() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

first_signal='process sample'
startup_ms='unmeasured'
startup_deadline=$(( $(date +%s) + 60 ))
if command -v xdotool >/dev/null 2>&1; then
  first_signal='visible window'
  while [ "$(date +%s)" -lt "$startup_deadline" ] && kill -0 "$pid" 2>/dev/null; do
    if xdotool search --onlyvisible --pid "$pid" --name '^Notes$' >/dev/null 2>&1; then
      startup_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
      break
    fi
    sleep 0.05
  done
else
  # RSS becoming non-zero is a bounded startup proxy, never a first-frame claim.
  while [ "$(date +%s)" -lt "$startup_deadline" ] && kill -0 "$pid" 2>/dev/null; do
    rss=$(awk '/^VmRSS:/ {print $2; found=1} END {if (!found) print 0}' "/proc/$pid/status" 2>/dev/null || echo 0)
    if [ "$rss" -gt 0 ]; then
      startup_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
      break
    fi
    sleep 0.05
  done
fi
if [ "$startup_ms" = 'unmeasured' ]; then
  echo 'No startup signal observed within 60 seconds.' >&2
  exit 1
fi
if ! kill -0 "$pid" 2>/dev/null; then
  echo 'Application exited before a startup signal was observed.' >&2
  exit 1
fi

read_proc() {
  # /proc/<pid>/stat fields 14 and 15 are user/system CPU ticks.
  sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $12 + $13}' 2>/dev/null || echo 0
}
read_rss_kib() {
  awk '/^VmRSS:/ {print $2; found=1} END {if (!found) print 0}' "/proc/$pid/status" 2>/dev/null || echo 0
}

cpu_before=$(read_proc)
rss_total=0
samples=0
idle_start=$(date +%s%N)
end=$(( $(date +%s) + idle_seconds ))
while [ "$(date +%s)" -lt "$end" ] && kill -0 "$pid" 2>/dev/null; do
  rss_total=$((rss_total + $(read_rss_kib)))
  samples=$((samples + 1))
  sleep 1
done
idle_end=$(date +%s%N)
cpu_after=$(read_proc)
elapsed_ns=$((idle_end - idle_start))
if [ "$samples" -eq 0 ] || [ "$elapsed_ns" -le 0 ]; then
  echo 'Application exited before idle sampling completed.' >&2
  exit 1
fi
cpu_ms=$(( (cpu_after - cpu_before) * 1000 / hz ))
cpu_tenths=$(( cpu_ms * 1000 / (elapsed_ns / 1000000) ))
rss_avg=$((rss_total / samples))

printf 'Signal\tStartup ms\tIdle CPU %%\tAvg RSS MiB\tIdle seconds\n'
printf '%s\t%s\t%d.%d\t%d\t%s\n' "$first_signal" "$startup_ms" "$((cpu_tenths / 10))" "$((cpu_tenths % 10))" "$((rss_avg / 1024))" "$idle_seconds"
