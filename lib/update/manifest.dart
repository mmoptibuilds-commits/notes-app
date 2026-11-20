import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'pinned_keys.dart';
import 'version_compare.dart';

/// Largest artifact the updater will accept (the APK is about 40 MB).
const kMaxArtifactBytes = 150 * 1024 * 1024;

/// Caps for the two small signature files, so a hostile server cannot make the
/// updater buffer something large.
const kMaxManifestBytes = 64 * 1024;
const kMaxSignatureBytes = 4 * 1024;

const kManifestAssetName = 'notes-manifest.json';
const kSignatureAssetName = 'notes-manifest.json.sig';

/// Why a manifest was refused. [message] is safe to show.
class ManifestException implements Exception {
  const ManifestException(this.message);
  final String message;

  @override
  String toString() => 'ManifestException: $message';
}

/// The exact artifact filename for a platform, derived from the version.
String expectedArtifactFilename(String platform, String arch, String version) =>
    switch ((platform, arch)) {
      ('linux', 'x64') => 'notes-$version-linux-x64.tar.gz',
      ('android', 'arm64') => 'notes-$version-android-arm64.apk',
      _ => '',
    };

class ManifestArtifact {
  const ManifestArtifact({
    required this.platform,
    required this.arch,
    required this.filename,
    required this.sha256,
    required this.size,
    this.versionCode,
    this.certSha256,
  });

  final String platform;
  final String arch;
  final String filename;

  /// 64 lowercase hex characters.
  final String sha256;
  final int size;

  /// Android only.
  final int? versionCode;

  /// Android only: SHA-256 of the signing certificate the APK must carry.
  final String? certSha256;
}

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.buildNumber,
    required this.publishedAt,
    required this.expires,
    required this.artifacts,
  });

  final String version;
  final int buildNumber;
  final DateTime publishedAt;
  final DateTime expires;
  final List<ManifestArtifact> artifacts;

  /// The single artifact for exactly this platform and architecture, or null.
  ManifestArtifact? artifactFor(String platform, String arch) {
    for (final a in artifacts) {
      if (a.platform == platform && a.arch == arch) return a;
    }
    return null;
  }
}

/// A manifest that passed validation. [signed] is false only when no key is
/// pinned in the app, in which case nothing about it is authenticated.
class VerifiedManifest {
  const VerifiedManifest(this.manifest, {required this.signed, this.keyId});
  final UpdateManifest manifest;
  final bool signed;
  final String? keyId;
}

final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _keyIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

/// Verifies and parses a release manifest.
///
/// Order matters: when keys are pinned the Ed25519 signature is checked over
/// the RAW bytes first, and only then are the bytes parsed. With no pinned key
/// the manifest is parsed unauthenticated ([VerifiedManifest.signed] false) and
/// the caller decides what that allows.
///
/// [expectedVersion] is the release tag without `v`; the manifest must say the
/// same. [now] is injectable for the expiry check.
Future<VerifiedManifest> verifyManifest({
  required Uint8List manifestBytes,
  required Uint8List? signatureBytes,
  required List<PinnedKey> keys,
  required String expectedVersion,
  required DateTime now,
  Ed25519? algorithm,
}) async {
  String? keyId;
  if (keys.isNotEmpty) {
    keyId = await _verifySignature(
      manifestBytes,
      signatureBytes,
      keys,
      algorithm ?? Ed25519(),
    );
  }
  final manifest = _parse(manifestBytes, expectedVersion, now);
  return VerifiedManifest(manifest, signed: keys.isNotEmpty, keyId: keyId);
}

Future<String> _verifySignature(
  Uint8List manifest,
  Uint8List? sigBytes,
  List<PinnedKey> keys,
  Ed25519 algorithm,
) async {
  if (sigBytes == null || sigBytes.isEmpty) {
    throw const ManifestException('The release has no signature file.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(sigBytes));
  } on FormatException {
    throw const ManifestException('The signature file is not valid.');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const ManifestException('The signature file is not valid.');
  }
  final keyId = decoded['keyId'];
  final alg = decoded['alg'];
  final sig = decoded['signature'];
  if (keyId is! String || !_keyIdPattern.hasMatch(keyId)) {
    throw const ManifestException('The signature names no valid key.');
  }
  if (alg != 'ed25519') {
    throw const ManifestException('Unsupported signature algorithm.');
  }
  if (sig is! String) {
    throw const ManifestException('The signature file is not valid.');
  }
  PinnedKey? key;
  for (final k in keys) {
    if (k.keyId == keyId) key = k;
  }
  if (key == null) {
    throw ManifestException('Signed with an unknown key ($keyId).');
  }
  final Uint8List sigRaw;
  final Uint8List pubRaw;
  try {
    sigRaw = base64.decode(sig);
    pubRaw = base64.decode(key.publicKey);
  } on FormatException {
    throw const ManifestException('The signature file is not valid.');
  }
  if (sigRaw.length != 64 || pubRaw.length != 32) {
    throw const ManifestException('The signature file is not valid.');
  }
  final ok = await algorithm.verify(
    manifest,
    signature: Signature(
      sigRaw,
      publicKey: SimplePublicKey(pubRaw, type: KeyPairType.ed25519),
    ),
  );
  if (!ok) {
    throw const ManifestException('The manifest signature does not match.');
  }
  return keyId;
}

UpdateManifest _parse(Uint8List bytes, String expectedVersion, DateTime now) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw const ManifestException('The manifest is not valid JSON.');
  }
  if (json is! Map<String, dynamic>) {
    throw const ManifestException('The manifest is not valid.');
  }
  if (json['schema'] != 1) {
    throw const ManifestException('Unsupported manifest version.');
  }
  if (json['app'] != kUpdateAppId) {
    throw const ManifestException('The manifest is for a different app.');
  }
  if (json['channel'] != 'stable') {
    throw const ManifestException(
      'The manifest is not for the stable channel.',
    );
  }
  final version = json['version'];
  if (version is! String ||
      SemVer.tryParse(version) == null ||
      SemVer.tryParse(version)!.isPrerelease) {
    throw const ManifestException('The manifest has an invalid version.');
  }
  if (version != expectedVersion) {
    throw const ManifestException(
      'The manifest version does not match the release.',
    );
  }
  final build = json['buildNumber'];
  if (build is! int || build <= 0) {
    throw const ManifestException('The manifest has an invalid build number.');
  }
  final published = _date(json['publishedAt']);
  final expires = _date(json['expires']);
  if (!expires.isAfter(now.toUtc())) {
    throw const ManifestException('The manifest has expired.');
  }
  final list = json['artifacts'];
  if (list is! List) {
    throw const ManifestException('The manifest lists no files.');
  }
  final artifacts = <ManifestArtifact>[];
  final seen = <String>{};
  for (final raw in list) {
    if (raw is! Map<String, dynamic>) {
      throw const ManifestException('The manifest has an invalid file entry.');
    }
    final platform = raw['platform'];
    final arch = raw['arch'];
    if (platform is! String || arch is! String) {
      throw const ManifestException('The manifest has an invalid file entry.');
    }
    final expectedName = expectedArtifactFilename(platform, arch, version);
    if (expectedName.isEmpty) continue; // a platform this app does not know
    if (!seen.add('$platform/$arch')) {
      throw const ManifestException('The manifest lists a file twice.');
    }
    final filename = raw['filename'];
    if (filename != expectedName) {
      throw const ManifestException('A file name in the manifest is wrong.');
    }
    final sha = raw['sha256'];
    if (sha is! String || !_hex64.hasMatch(sha)) {
      throw const ManifestException('A checksum in the manifest is invalid.');
    }
    final size = raw['size'];
    if (size is! int || size <= 0 || size > kMaxArtifactBytes) {
      throw const ManifestException('A file size in the manifest is invalid.');
    }
    int? versionCode;
    String? cert;
    if (platform == 'android') {
      final vc = raw['versionCode'];
      if (vc is! int || vc <= 0) {
        throw const ManifestException('The Android version code is invalid.');
      }
      versionCode = vc;
      final c = raw['certSha256'];
      if (c is! String || !_hex64.hasMatch(c)) {
        throw const ManifestException(
          'The Android certificate fingerprint is invalid.',
        );
      }
      cert = c;
    }
    artifacts.add(
      ManifestArtifact(
        platform: platform,
        arch: arch,
        filename: filename as String,
        sha256: sha,
        size: size,
        versionCode: versionCode,
        certSha256: cert,
      ),
    );
  }
  return UpdateManifest(
    version: version,
    buildNumber: build,
    publishedAt: published,
    expires: expires,
    artifacts: artifacts,
  );
}

DateTime _date(Object? v) {
  if (v is! String) {
    throw const ManifestException('The manifest has an invalid date.');
  }
  final d = DateTime.tryParse(v);
  if (d == null || !d.isUtc) {
    throw const ManifestException('The manifest has an invalid date.');
  }
  return d;
}
