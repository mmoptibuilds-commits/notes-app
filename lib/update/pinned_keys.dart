/// An Ed25519 public key the app trusts to sign update manifests.
class PinnedKey {
  const PinnedKey({required this.keyId, required this.publicKey});

  /// Identifier named by the `keyId` field of `notes-manifest.json.sig`.
  final String keyId;

  /// Base64 of the 32 raw public key bytes.
  final String publicKey;
}

/// Manifest signing keys compiled into the app.
///
/// `notes-release-1` was generated offline by the owner on 2026-11-21. Its
/// private key exists only as encrypted backups, never in the repository or
/// CI. A test keeps this list equal to `tool/release_signing_pubkeys.json` and
/// to the PEM key and fingerprint published in README.md. More than one key may
/// be listed so a key can be rotated by shipping the new public key one release
/// ahead (see docs/UPDATES.md).
const List<PinnedKey> kPinnedKeys = <PinnedKey>[
  PinnedKey(
    keyId: 'notes-release-1',
    publicKey: '0Fp4/rw2KnbJD7bt6tA2spIhMTLLFtJwYiEHaivaXzM=',
  ),
];

/// SHA-256 of the Android release signing certificate. An APK is installable
/// by this updater only when its single signer matches. A test keeps it equal
/// to `tool/release_cert_sha256.txt`.
const kReleaseCertSha256 =
    '3a1730a612be926bae09cb362bcdcca5907fabf01d4d2598e96347bddc0c8ca1';

/// The application id every update artifact must carry.
const kUpdateAppId = 'com.mmoptibuilds.notes';
