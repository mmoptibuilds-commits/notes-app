# Update trust and limits

## Trust model

The app retrieves release metadata, verifies the Ed25519 signature against a
public key pinned in the app, checks the signature over the raw manifest bytes,
then parses the manifest and validates its schema, app id, channel, expiry,
version and artifact metadata. It checks downloaded bytes against the signed
SHA-256 and size. A release's signature authenticates the manifest; a pinned
key establishes which publisher the app trusts.

Stable releases use `notes-manifest.json` and
`notes-manifest.json.sig`. The preview tag is a pre-release and does not count
as a stable release. If GitHub has no stable release, the app must say “No
stable release published.” Expired manifests are rejected. The app does not
allow downgrades; recorded update bookkeeping is persisted silently. The
published timestamp and monotonic build/version checks limit replay of older
releases.

The production key list currently has no provisioned key. Update checks can
still discover release metadata, but automatic Linux replacement is blocked
with “release signing key not provisioned.” Tests use throwaway keys only.

## Offline production key provisioning

On an offline machine controlled by the owner, generate an Ed25519 keypair
with `dart tool/release/keygen.dart --private-key /offline/path/private.json
--public-key /offline/path/public.json --key-id <id>`. Keep the private key
readable only by its owner (mode 0600), make an offline backup, and never put it
in the repository, CI, environment variables, or a GitHub secret. Add only the
public key's id and base64 public key to `lib/update/pinned_keys.dart` and
`tool/release_signing_pubkeys.json`. Sign each release manifest locally with
`tool/release/sign_manifest.dart`; CI must never hold the signing key.

For key rotation, ship an app update pinning the next public key while retaining
the old key for the overlap period. Sign with the old key until that app update
is available, then sign releases with the new key. Remove the old pin only
after supported installs have received the rotation update. Never replace a
lost private key by silently reusing its id.

The checked-in
`tool/release_signing_pubkeys.json` is an empty JSON list until provisioning.
The app's `lib/update/pinned_keys.dart` is owned by the coordinator; this
worker does not change it.

## Linux helper

After the app verifies the manifest and artifact hash/size, it can pass the
archive and signed metadata values to the installed helper. The helper copies
itself to a private temporary directory before execution, waits for the app to
exit, validates the archive, stages it beside the installation, then swaps
program directories. It uses `flock`, checks the managed marker and current
user ownership, and never runs `sudo`. It has no network or signature
verification code: the app is responsible for verification before invoking
it. Status is written to
`${XDG_STATE_HOME:-~/.local/state}/com.mmoptibuilds.notes/updater/update.json`.
The helper never accesses the notes database, keyring, backups, or pairing
data. It requires GNU tar, `flock`, `sha256sum`, and `/proc`.

Rollback is automatic only when the program-directory swap fails. After a new
version has opened the database, an older version may reject that database
with `DatabaseTooNewException`; manual rollback is therefore not guaranteed
to restore a launchable app after database migration.

## Android

The signed manifest pins the expected APK signing-certificate SHA-256. The app
checks artifact hash, size, versionCode and certificate pin, then hands the APK
to Android's package installer. Android still displays its install/update UI.
Distribution through Google Play would need to use Play's update flow and
signing identity rather than direct APK delivery.
