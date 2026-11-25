#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/development/flutter/bin:$PATH"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
export ORG_GRADLE_PROJECT_cloudTest=true

# The default server is the owner's real one: a test build must name its own.
case " $* " in
  *"notes-sync.mmoptibuilds"*)
    echo "error: a test build must not point at the production Worker" >&2; exit 2 ;;
  *"NOTES_CLOUD_URL="*) ;;
  *) echo "error: pass --dart-define=NOTES_CLOUD_URL=<test worker url>" >&2; exit 2 ;;
esac

flutter build apk --release --target-platform android-arm64 "$@"

apk="build/app/outputs/flutter-apk/app-release.apk"
apksigner="$HOME/Android/Sdk/build-tools/36.0.0/apksigner"
aapt="$HOME/Android/Sdk/build-tools/36.0.0/aapt"
test -f "$apk"
test -x "$apksigner"
test -x "$aapt"
version_name=$("$aapt" dump badging "$apk" | sed -n "s/^package:.*versionName='\([^']*\)'.*/\1/p")
version_code=$("$aapt" dump badging "$apk" | sed -n "s/^package:.*versionCode='\([^']*\)'.*/\1/p")
application_id=$("$aapt" dump badging "$apk" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
certificate_sha1=$("$apksigner" verify --print-certs "$apk" | sed -n 's/^Signer #1 certificate SHA-1 digest: //p')
printf 'APK: %s\nVersion name: %s\nVersion code: %s\nApplication id: %s\nSigning certificate SHA-1: %s\n' \
  "$apk" "$version_name" "$version_code" "$application_id" "$certificate_sha1"
