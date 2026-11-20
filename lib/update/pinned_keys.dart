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
/// Empty until the owner provisions a production key. While it is empty the
/// app can still CHECK for updates, but Linux installation is blocked
/// ("release signing key not provisioned"). To provision: generate an Ed25519
/// key pair offline, keep the private key off this machine and the repo, add
/// `PinnedKey(keyId: '...', publicKey: '<base64 of 32 raw bytes>')` here, and
/// sign every release manifest with it. More than one key may be listed so a
/// key can be rotated by shipping the new public key one release ahead.
const List<PinnedKey> kPinnedKeys = <PinnedKey>[];

/// SHA-256 of the Android release signing certificate. An APK is installable
/// by this updater only when its single signer matches. A test keeps it equal
/// to `tool/release_cert_sha256.txt`.
const kReleaseCertSha256 =
    '3a1730a612be926bae09cb362bcdcca5907fabf01d4d2598e96347bddc0c8ca1';

/// The application id every update artifact must carry.
const kUpdateAppId = 'com.mmoptibuilds.notes';
