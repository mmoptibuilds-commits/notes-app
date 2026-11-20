# Update trust and limits

## Trust model

**Linux.** The app requires a pinned public key. It verifies the Ed25519
signature over the raw manifest bytes, then parses the manifest and validates
its schema, app id, channel, expiry, version and artifact metadata, and checks
the downloaded bytes against the signed SHA-256 and size. With no key pinned,
Linux installation is blocked ("release signing key not provisioned").

**Android.** Authenticity rests on the APK's signing certificate, which must
match the certificate pinned in the app, plus Android's own installer, which
only accepts an update signed by the same key and always asks the user. The
manifest signature is additionally required once a key is pinned. While no key
is pinned the metadata is unsigned, and the Updates screen says so.

**Replay and downgrade.** The app records the highest verified manifest
version and build and rejects anything lower. It does not allow downgrades and
rejects expired manifests. The `publishedAt` field is informational; it is not
used for replay checks. Bookkeeping is persisted silently.

**Manual installs.** `tool/release/verify_manifest.dart --artifact FILE` checks
the signature and then hashes the file you downloaded against the signed
manifest. The checksum sidecar alone only detects a damaged download.

Stable releases use `notes-manifest.json` and `notes-manifest.json.sig`. The
preview tag is a pre-release and does not count as a stable release. If GitHub
has no stable release, the app says "No stable release published."

The production key list currently has no provisioned key. Update checks can
still discover release metadata, but automatic Linux replacement is blocked.
Tests use throwaway keys only.

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
