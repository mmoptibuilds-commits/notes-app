/// Version comparison for updates. Never compares version strings
/// lexicographically: `1.0.10` is newer than `1.0.9`.
///
/// Linux compares semantic versions (semver 2.0, build metadata ignored) and
/// uses the build number only as a tie-break. Android compares the integer
/// versionCode, which is what the package manager itself enforces.
library;

final _semverPattern = RegExp(
  r'^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})'
  r'(?:-((?:0|[1-9]\d{0,8}|\d*[A-Za-z-][0-9A-Za-z-]*)'
  r'(?:\.(?:0|[1-9]\d{0,8}|\d*[A-Za-z-][0-9A-Za-z-]*))*))?'
  r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
);

/// A parsed semantic version. Numeric parts are limited to nine digits so
/// they always fit an int, whatever platform the app runs on.
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch, [this.pre = const []]);

  final int major;
  final int minor;
  final int patch;

  /// Pre-release identifiers (`rc.1` -> `['rc', '1']`); empty for a release.
  final List<String> pre;

  /// Strict semver 2.0. Returns null for anything else, including a leading
  /// `v`, leading zeros, or missing parts.
  static SemVer? tryParse(String text) {
    final m = _semverPattern.firstMatch(text);
    if (m == null) return null;
    return SemVer(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      m[4] == null ? const [] : m[4]!.split('.'),
    );
  }

  bool get isPrerelease => pre.isNotEmpty;

  @override
  int compareTo(SemVer other) {
    var c = major.compareTo(other.major);
    if (c != 0) return c;
    c = minor.compareTo(other.minor);
    if (c != 0) return c;
    c = patch.compareTo(other.patch);
    if (c != 0) return c;
    // A version without a pre-release is greater than one with.
    if (pre.isEmpty && other.pre.isEmpty) return 0;
    if (pre.isEmpty) return 1;
    if (other.pre.isEmpty) return -1;
    final n = pre.length < other.pre.length ? pre.length : other.pre.length;
    for (var i = 0; i < n; i++) {
      c = _compareIdentifier(pre[i], other.pre[i]);
      if (c != 0) return c;
    }
    return pre.length.compareTo(other.pre.length);
  }

  static int _compareIdentifier(String a, String b) {
    final an = int.tryParse(a);
    final bn = int.tryParse(b);
    if (an != null && bn != null) return an.compareTo(bn);
    // Numeric identifiers are lower than alphanumeric ones.
    if (an != null) return -1;
    if (bn != null) return 1;
    return a.compareTo(b);
  }

  @override
  String toString() =>
      '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}

/// Whether a Linux candidate is strictly newer than what is installed: a
/// higher semantic version, or the same version with a higher build number.
/// Equal and older are never updates (no downgrade). Returns false when either
/// version is not valid semver.
bool isNewerLinuxVersion({
  required String installedVersion,
  required int installedBuild,
  required String candidateVersion,
  required int candidateBuild,
}) {
  final installed = SemVer.tryParse(installedVersion);
  final candidate = SemVer.tryParse(candidateVersion);
  if (installed == null || candidate == null) return false;
  final c = candidate.compareTo(installed);
  if (c != 0) return c > 0;
  return candidateBuild > installedBuild;
}

/// Whether an Android candidate is strictly newer: a higher versionCode.
bool isNewerAndroidVersionCode({
  required int installedVersionCode,
  required int candidateVersionCode,
}) => candidateVersionCode > installedVersionCode;

/// Orders manifests for replay protection: negative when `a` is older than `b`.
int compareReleases(String versionA, int buildA, String versionB, int buildB) {
  final a = SemVer.tryParse(versionA);
  final b = SemVer.tryParse(versionB);
  if (a == null || b == null) return 0;
  final c = a.compareTo(b);
  return c != 0 ? c : buildA.compareTo(buildB);
}
