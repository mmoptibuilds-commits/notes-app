# Update trust and limits

## Trust model

**Linux.** The app requires a pinned public key. It verifies the Ed25519
signature over the raw manifest bytes, then parses the manifest and validates
its schema, app id, channel, expiry, version and artifact metadata, and checks
the downloaded bytes against the signed SHA-256 and size. The pinned key is
`notes-release-1` (see "Production key" below).

**Android.** Authenticity rests on the APK's signing certificate, which must
match the certificate pinned in the app, plus Android's own installer, which
only accepts an update signed by the same key and always asks the user. The
manifest signature is required because a key is pinned: there is no
unsigned fallback on either Android or Linux.

**Replay and downgrade.** The app records the highest signed manifest version
and build it has verified and rejects anything lower. Retracting a newer
release therefore makes later checks fail until a newer release is published.
The `publishedAt` field is informational; it is not used for replay checks.
Bookkeeping is persisted silently.

## Automatic checks, downloads and ready state

Automatic updates are on by default. Notes restores a saved ready update and
starts its first check a few seconds after the first frame. It also checks on
resume when the last successful check is at least 24 hours old. Failed checks
use bounded exponential backoff starting at one hour and capped at 24 hours;
GitHub `Retry-After` is respected. Automatic work does not run in an instance
started with `NOTES_DATA_DIR`. Turning the setting off cancels queued automatic
downloads. Manual Check, Download and Install remain available.

When an automatic check finds a newer signed release, Notes downloads the
artifact in the background. A partial transfer has a small sidecar bound to its
HTTPS URL, version, declared size and SHA-256. Resume is allowed only when the
partial has a strong server ETag and the server confirms the same ETag and a
matching 206 `Content-Range` for the requested byte range. If there is no strong
ETag, the server ignores the range, or the ETag changes, Notes starts a fresh
download from byte zero. It hashes the complete file before atomically renaming
it. Cancellation and network loss leave a paused download that resumes (or
restarts) on the next attempt. Too little free space is a failure, not a pause:
Notes shows how much space it needs and offers **Retry download**. Either way
the next attempt verifies the complete file.

After verification Notes persists a compact ready record containing the raw
manifest bytes and signature, artifact metadata and release address. Android
keeps the artifact under app-private `filesDir/updates` (not cache); Linux uses
the XDG state updates directory. Restore and every install repeat signature,
expiry, replay-order, file-size and SHA-256 checks. Android also repeats package
id, versionCode and pinned signing-certificate checks. The app-level ready
banner offers **Install now** and **Later**; Later hides it for the rest of that
launch, while Settings → Updates continues to offer Install. Installation always
waits for the app confirmation and the platform installer confirmation.

**Manual installs.** Users verify with OpenSSL 3 as described in README
"Verify a Linux download". Maintainers can also run
`tool/release/verify_manifest.dart --artifact FILE`, which checks the signature
and then hashes the file against the signed manifest. The checksum sidecar
alone only detects a damaged download.

Stable releases use `notes-manifest.json` and `notes-manifest.json.sig`. The
first stable release is v1.0.0 (build 20261123). Pre-releases such as
`v1.0.0-preview.1` never count as stable. If GitHub has no stable release, the
app shows “No stable release published.”

## Production key

| | |
|---|---|
| Key id | `notes-release-1` |
| Algorithm | Ed25519; signature over the raw bytes of `notes-manifest.json` |
| Public key (base64, 32 bytes) | `0Fp4/rw2KnbJD7bt6tA2spIhMTLLFtJwYiEHaivaXzM=` |
| SHA-256 of the DER SPKI | `6947c0cb0e4311f7579a37d028f5b5e013326f93935b2b918cacfbd7a0ed0471` |
| Generated | 2026-11-21 by the owner with `tool/release/keygen.dart`, in RAM (`/dev/shm`) |

The key is pinned in `lib/update/pinned_keys.dart` and listed in
`tool/release_signing_pubkeys.json`; README publishes the PEM and fingerprint.
A test (`test/update/manifest_test.dart`) fails if the three disagree. The
first published stable build must contain this key, or its users could never
verify a signed update.

**Private key custody.** The private key exists only as a GPG-encrypted file
(AES-256, passphrase held by the owner): one copy in a private local backup
directory on the owner's laptop and one in the owner's Google Drive. Both
copies were decrypted and compared byte for byte with the original before the
plaintext was deleted. Neither copy is offline: the Drive copy is protected
only by the passphrase, and the laptop copy shares the laptop's fate. Add an
offline copy (USB or paper) when one is available. Never put the private key
in the repository, CI, environment variables or GitHub secrets.

**Signing a release.** Decrypt one backup into a fresh `/dev/shm` directory in
a shell with `ulimit -c 0` and history off, sign with
`tool/release/sign_manifest.dart`, verify, then delete the directory. Steps are
in [RELEASE.md](RELEASE.md). Decrypting also re-tests backup recovery.

`kPinnedKeys` may contain several keys. For rotation, ship the new public key
in a release signed by the old key, then sign later releases with the new key.
Remove the old key only after users have moved to a build that trusts the new
key. Never reuse a key id.

## Manifest expiry, re-signing and key rotation

Expiry is enforced against the device clock. If the latest stable release's
manifest has expired, the Updates screen reports “Could not verify the update”
with “The manifest has expired”; nothing is installed, including when the app
would otherwise be up to date. Use an expiry about 24 months after publication.
Re-sign well before expiry, for example
three months ahead: replace the manifest and signature assets on the same
release with a new `expires` and `publishedAt` while keeping the same artifact
bytes, or publish a new release. `publishedAt` does not affect replay checks.

A device clock far ahead of the real time can make the manifest appear expired
and fail closed. A clock behind real time does not affect signature
verification.

The app records the highest signed `(version, build)` it has verified and
refuses older manifests. Retracting a newer release causes later checks to fail
until a newer one is published.

If the private key is lost, nobody can sign updates for builds that trust only
that key. Recovery requires a new key and a new build that users install
manually. On Android, the same APK certificate still permits an in-place
install through the system installer. Never reuse a key id.

If the manifest key is compromised, an attacker could sign manifests. To harm
users they also need to place files on this project's GitHub release. Then
Linux installs would accept a malicious archive whose hash the attacker signed;
Android additionally requires the pinned APK signing certificate, which the
manifest key cannot replace. Respond by publishing a new build that pins a new
key and drops the compromised one, and announce the change in README.

There is no unsigned fallback once a key is pinned. Android and Linux both
require the signature.

`tool/release_signing_pubkeys.json` and `lib/update/pinned_keys.dart` must
always list the same keys.

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
The helper holds `${stateDir}/lock` with `flock` from before its process scan
through the swap. Startup checks the same lock before opening the database,
waiting up to ten seconds before showing a clear retry message. The helper
relaunches the updated Notes app after a successful swap and reopens the
previous app after a failed update. It checks free space on the install parent
for extraction and staging before it creates either directory. The helper
never accesses the notes database, keyring, backups, or pairing data. It
requires GNU tar, `flock`, `sha256sum`, `df`, `/proc` and `setsid` for relaunch.

Rollback is automatic only when the program-directory swap fails. After a new
version has opened the database, an older version may reject that database
with `DatabaseTooNewException`; manual rollback is therefore not guaranteed
to restore a launchable app after database migration.

## Android

The signed manifest pins the expected APK signing-certificate SHA-256. The app
checks artifact hash, size, versionCode and certificate pin, then hands the APK
to Android's package installer. Android still displays its install/update UI.
Artifacts and the durable pending-install marker live in app-private
`filesDir/updates`. On Android 13 and newer, Notes asks for notification
permission only after the user taps Install. After replacement, a private
receiver checks that the pending versionCode matches the installed package and
posts “Notes updated — tap to open” with an explicit Activity PendingIntent. It
never launches an Activity from the background. If notifications are denied,
the update still completes and the next launch shows the one-time “Updated to
version X” result instead.
Distribution through Google Play would need to use Play's update flow and
signing identity rather than direct APK delivery.
