#!/bin/sh
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
lock="$tmp/updater.lock"

# Model the helper holding the shared lock across its swap.
flock -n "$lock" /bin/sh -c 'sleep 1' &
holder=$!
sleep 0.1

if flock -n "$lock" /bin/true; then
  echo 'startup acquired the lock while the updater held it' >&2
  exit 1
fi
flock -w 3 "$lock" /bin/true
wait "$holder"
