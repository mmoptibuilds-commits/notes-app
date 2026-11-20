import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'update_http.dart';
import 'version_compare.dart';

const kUpdateRepo = 'mmoptibuilds-commits/notes-app';
final kLatestReleaseUrl = Uri.https(
  'api.github.com',
  '/repos/$kUpdateRepo/releases/latest',
);

/// The release JSON is small; anything over this is refused.
const kMaxReleaseJsonBytes = 1024 * 1024;

/// Release notes kept for display; the rest is dropped.
const kMaxReleaseNotesChars = 20000;

class GithubAsset {
  const GithubAsset({
    required this.name,
    required this.size,
    required this.downloadUrl,
  });

  final String name;
  final int size;
  final Uri downloadUrl;
}

class GithubRelease {
  const GithubRelease({
    required this.tag,
    required this.version,
    required this.notes,
    required this.assets,
  });

  /// `v1.0.1`.
  final String tag;

  /// The tag without its `v`.
  final String version;
  final String notes;
  final List<GithubAsset> assets;

  GithubAsset? asset(String name) {
    for (final a in assets) {
      if (a.name == name) return a;
    }
    return null;
  }

  /// Strictly validates the shape of a GitHub release object. Throws
  /// [FormatException] for anything unexpected. A draft or pre-release is not
  /// a stable release and is reported through [isStable] instead.
  static GithubRelease parse(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    if (tag is! String || !tag.startsWith('v')) {
      throw const FormatException('tag_name');
    }
    final version = tag.substring(1);
    if (SemVer.tryParse(version) == null) {
      throw const FormatException('tag_name is not a version');
    }
    final body = json['body'];
    if (body != null && body is! String) throw const FormatException('body');
    final assets = json['assets'];
    if (assets is! List) throw const FormatException('assets');
    final out = <GithubAsset>[];
    for (final a in assets) {
      if (a is! Map<String, dynamic>) throw const FormatException('asset');
      final name = a['name'];
      final size = a['size'];
      final url = a['browser_download_url'];
      if (name is! String || name.isEmpty || size is! int || size < 0) {
        throw const FormatException('asset fields');
      }
      if (url is! String) throw const FormatException('asset url');
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        throw const FormatException('asset url is not https');
      }
      out.add(GithubAsset(name: name, size: size, downloadUrl: uri));
    }
    var notes = (body as String?) ?? '';
    if (notes.length > kMaxReleaseNotesChars) {
      notes = notes.substring(0, kMaxReleaseNotesChars);
    }
    return GithubRelease(tag: tag, version: version, notes: notes, assets: out);
  }

  /// Whether a decoded release object says it is published and stable.
  /// Requires both flags to be present booleans.
  static bool isStable(Map<String, dynamic> json) {
    final draft = json['draft'];
    final pre = json['prerelease'];
    if (draft is! bool || pre is! bool) {
      throw const FormatException('draft/prerelease');
    }
    return !draft && !pre;
  }
}

sealed class ReleaseFetch {
  const ReleaseFetch();
}

/// A release, with the ETag and the exact JSON that produced it (so a later
/// 304 can be answered from a cache).
class ReleaseFetched extends ReleaseFetch {
  const ReleaseFetched(this.release, {this.etag, required this.rawJson});
  final GithubRelease release;
  final String? etag;
  final String rawJson;
}

/// 304: nothing changed since the ETag the caller sent.
class ReleaseNotModified extends ReleaseFetch {
  const ReleaseNotModified();
}

/// 404 (no stable release exists) or a response that is not a stable release.
class ReleaseNone extends ReleaseFetch {
  const ReleaseNone();
}

class ReleaseRateLimited extends ReleaseFetch {
  const ReleaseRateLimited(this.resetAt);
  final DateTime? resetAt;
}

class ReleaseOffline extends ReleaseFetch {
  const ReleaseOffline();
}

class ReleaseFailed extends ReleaseFetch {
  const ReleaseFailed(this.message);
  final String message;
}

/// Asks the GitHub REST API for the latest stable release of the app. Never
/// scrapes HTML, never sends a token, and sends nothing identifying: a fixed
/// generic User-Agent and the standard API headers.
class GithubReleaseClient {
  GithubReleaseClient(
    this._http, {
    this.totalTimeout = const Duration(seconds: 20),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final UpdateHttp _http;
  final Duration totalTimeout;
  final DateTime Function() _now;

  Future<ReleaseFetch> fetchLatest({String? etag}) async {
    try {
      return await _fetch(etag).timeout(totalTimeout);
    } on TimeoutException {
      return const ReleaseFailed('GitHub did not answer in time.');
    } on UpdateOfflineException {
      return const ReleaseOffline();
    } on SocketException {
      return const ReleaseOffline();
    } on IOException {
      return const ReleaseFailed('The connection to GitHub was interrupted.');
    } on UpdateProtocolException catch (e) {
      return ReleaseFailed(e.message);
    } on BodyTooLargeException {
      return const ReleaseFailed('GitHub sent an unexpectedly large answer.');
    }
  }

  Future<ReleaseFetch> _fetch(String? etag) async {
    final response = await getFollowingRedirects(
      _http,
      kLatestReleaseUrl,
      headers: {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Notes-update-check',
        if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
      },
    );
    final status = response.status;
    if (status == 304) {
      await response.close();
      return const ReleaseNotModified();
    }
    if (status == 404) {
      await response.close();
      return const ReleaseNone();
    }
    if (status == 403 || status == 429) {
      final h = response.headers;
      await response.close();
      final limited =
          h['x-ratelimit-remaining'] == '0' ||
          h.containsKey('retry-after') ||
          status == 429;
      if (!limited) {
        return ReleaseFailed('GitHub refused the request ($status).');
      }
      return ReleaseRateLimited(_resetTime(h));
    }
    if (status != 200) {
      await response.close();
      return ReleaseFailed('GitHub answered with status $status.');
    }
    final type = response.headers['content-type'] ?? '';
    if (!type.toLowerCase().contains('json')) {
      await response.close();
      return const ReleaseFailed('GitHub sent an unexpected kind of answer.');
    }
    final bytes = await readBodyCapped(
      response,
      maxBytes: kMaxReleaseJsonBytes,
      timeout: totalTimeout,
    );
    final String raw;
    final Object? decoded;
    try {
      raw = utf8.decode(bytes);
      decoded = jsonDecode(raw);
    } on FormatException {
      return const ReleaseFailed('GitHub sent an answer Notes cannot read.');
    }
    if (decoded is! Map<String, dynamic>) {
      return const ReleaseFailed('GitHub sent an answer Notes cannot read.');
    }
    try {
      if (!GithubRelease.isStable(decoded)) return const ReleaseNone();
      final release = GithubRelease.parse(decoded);
      return ReleaseFetched(
        release,
        etag: response.headers['etag'],
        rawJson: raw,
      );
    } on FormatException {
      return const ReleaseFailed('GitHub sent an answer Notes cannot read.');
    }
  }

  DateTime? _resetTime(Map<String, String> h) {
    final retry = int.tryParse(h['retry-after'] ?? '');
    if (retry != null && retry >= 0) {
      return _now().add(Duration(seconds: retry));
    }
    final reset = int.tryParse(h['x-ratelimit-reset'] ?? '');
    if (reset != null && reset > 0) {
      return DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
    }
    return null;
  }

  /// Re-parses a cached release body. Null when it no longer validates.
  static GithubRelease? parseCached(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          !GithubRelease.isStable(decoded)) {
        return null;
      }
      return GithubRelease.parse(decoded);
    } on FormatException {
      return null;
    }
  }
}
