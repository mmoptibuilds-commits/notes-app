import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/update/github_release_client.dart';
import 'package:notes/update/update_http.dart';

import 'fake_http.dart';

final _url = kLatestReleaseUrl.toString();

Map<String, Object?> releaseJson({
  String tag = 'v1.0.1',
  bool draft = false,
  bool prerelease = false,
  Object? assets,
  Object? body = 'Notes for 1.0.1',
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'body': body,
  'assets':
      assets ??
      [
        {
          'name': 'notes-manifest.json',
          'size': 400,
          'browser_download_url':
              'https://github.com/x/y/releases/download/$tag/notes-manifest.json',
        },
      ],
};

FakeReply ok(
  Object? json, {
  Map<String, String> headers = const {},
  String type = 'application/json; charset=utf-8',
}) => FakeReply(
  200,
  body: utf8.encode(json is String ? json : jsonEncode(json)),
  headers: {'content-type': type, ...headers},
);

void main() {
  late FakeHttp http;
  late GithubReleaseClient client;
  setUp(() {
    http = FakeHttp();
    client = GithubReleaseClient(
      http,
      totalTimeout: const Duration(milliseconds: 200),
      now: () => DateTime.utc(2026, 12, 1, 12),
    );
  });

  test(
    'sends exactly the documented headers and no identifying ones',
    () async {
      http.on(_url, ok(releaseJson(), headers: {'etag': 'W/"abc"'}));
      final r = await client.fetchLatest(etag: 'W/"old"');
      expect(r, isA<ReleaseFetched>());
      final sent = http.requests.single;
      expect(sent.url.toString(), startsWith('https://api.github.com/repos/'));
      expect(sent.headers, {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Notes-update-check',
        'If-None-Match': 'W/"old"',
      });
    },
  );

  test('without a stored etag no If-None-Match is sent', () async {
    http.on(_url, ok(releaseJson()));
    await client.fetchLatest();
    expect(http.requests.single.headers.containsKey('If-None-Match'), isFalse);
  });

  test('a stable release parses, keeping the etag and the raw json', () async {
    http.on(_url, ok(releaseJson(), headers: {'etag': 'W/"abc"'}));
    final r = await client.fetchLatest() as ReleaseFetched;
    expect(r.etag, 'W/"abc"');
    expect(r.release.tag, 'v1.0.1');
    expect(r.release.version, '1.0.1');
    expect(r.release.notes, 'Notes for 1.0.1');
    expect(r.release.asset('notes-manifest.json')!.size, 400);
    expect(r.release.asset('missing'), isNull);
    expect(GithubReleaseClient.parseCached(r.rawJson)!.tag, 'v1.0.1');
  });

  test('304 means unchanged', () async {
    http.on(_url, FakeReply(304));
    expect(await client.fetchLatest(etag: 'x'), isA<ReleaseNotModified>());
  });

  test('404 means no stable release (not an error)', () async {
    http.on(_url, FakeReply(404, body: utf8.encode('{"message":"Not Found"}')));
    expect(await client.fetchLatest(), isA<ReleaseNone>());
  });

  test('a prerelease or draft in a 200 is not a stable release', () async {
    http.on(_url, ok(releaseJson(prerelease: true)));
    expect(await client.fetchLatest(), isA<ReleaseNone>());
    http.replace(_url, ok(releaseJson(draft: true)));
    expect(await client.fetchLatest(), isA<ReleaseNone>());
  });

  group('rate limits', () {
    test('403 with no requests remaining reports the reset time', () async {
      http.on(
        _url,
        FakeReply(
          403,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '1796126400',
          },
        ),
      );
      final r = await client.fetchLatest() as ReleaseRateLimited;
      expect(r.resetAt, DateTime.utc(2026, 12, 1, 12));
    });

    test('429 with retry-after is relative to now', () async {
      http.on(_url, FakeReply(429, headers: {'retry-after': '90'}));
      final r = await client.fetchLatest() as ReleaseRateLimited;
      expect(r.resetAt, DateTime.utc(2026, 12, 1, 12, 1, 30));
    });

    test('a plain 403 is a failure, not a rate limit', () async {
      http.on(_url, FakeReply(403));
      expect(await client.fetchLatest(), isA<ReleaseFailed>());
    });
  });

  group('failures', () {
    test('no network', () async {
      http.on(_url, FakeReply(0, error: const UpdateOfflineException()));
      expect(await client.fetchLatest(), isA<ReleaseOffline>());
      http.replace(_url, FakeReply(0, error: const SocketException('down')));
      expect(await client.fetchLatest(), isA<ReleaseOffline>());
    });

    test('timeout', () async {
      http.on(_url, FakeReply(200, hang: true));
      final r = await client.fetchLatest();
      expect(r, isA<ReleaseFailed>());
      expect((r as ReleaseFailed).message, contains('in time'));
    });

    test('a connection reset mid-body counts as offline', () async {
      http.on(
        _url,
        FakeReply(
          200,
          headers: {'content-type': 'application/json'},
          chunks: [utf8.encode('{"a":')],
          streamError: const SocketException('reset'),
        ),
      );
      expect(await client.fetchLatest(), isA<ReleaseOffline>());
    });

    test('server errors', () async {
      http.on(_url, FakeReply(500));
      expect(await client.fetchLatest(), isA<ReleaseFailed>());
    });

    test('invalid JSON', () async {
      http.on(_url, ok('{not json'));
      expect(await client.fetchLatest(), isA<ReleaseFailed>());
      http.replace(_url, ok('[]'));
      expect(await client.fetchLatest(), isA<ReleaseFailed>());
    });

    test('unexpected content type (an HTML page)', () async {
      http.on(_url, ok('<html></html>', type: 'text/html'));
      expect(await client.fetchLatest(), isA<ReleaseFailed>());
    });

    test('an oversized body is aborted', () async {
      final big = List<int>.filled(kMaxReleaseJsonBytes + 10, 0x20);
      http.on(
        _url,
        FakeReply(
          200,
          headers: {'content-type': 'application/json'},
          chunks: [big.sublist(0, 600000), big.sublist(600000)],
        ),
      );
      final r = await client.fetchLatest();
      expect((r as ReleaseFailed).message, contains('large'));
    });

    test('a declared oversized body is refused before reading', () async {
      http.on(
        _url,
        FakeReply(
          200,
          headers: {
            'content-type': 'application/json',
            'content-length': '${kMaxReleaseJsonBytes + 1}',
          },
          body: const [0x7b],
        ),
      );
      expect(await client.fetchLatest(), isA<ReleaseFailed>());
    });

    test('strict shape validation', () async {
      final cases = <Map<String, Object?>>[
        releaseJson(tag: '1.0.1'),
        releaseJson(tag: 'vNext'),
        releaseJson(tag: 'v1.0'),
        releaseJson(assets: 'nope'),
        releaseJson(assets: [1]),
        releaseJson(body: 5),
        releaseJson(
          assets: [
            {'name': 'a', 'size': 1, 'browser_download_url': 'http://x/a'},
          ],
        ),
        releaseJson(
          assets: [
            {'name': 'a', 'size': '1', 'browser_download_url': 'https://x/a'},
          ],
        ),
        releaseJson(
          assets: [
            {'name': 'a', 'size': 1, 'browser_download_url': 5},
          ],
        ),
        {...releaseJson()}..remove('draft'),
        {...releaseJson(), 'prerelease': 'false'},
      ];
      for (final c in cases) {
        http.routes.clear();
        http.on(_url, ok(c));
        expect(await client.fetchLatest(), isA<ReleaseFailed>(), reason: '$c');
      }
    });

    test('a redirect from the API is followed only over https', () async {
      http.on(
        _url,
        FakeReply(301, headers: {'location': 'http://evil.example/x'}),
      );
      expect(await client.fetchLatest(), isA<ReleaseFailed>());
    });
  });

  test('long release notes are truncated', () async {
    http.on(_url, ok(releaseJson(body: 'x' * (kMaxReleaseNotesChars + 500))));
    final r = await client.fetchLatest() as ReleaseFetched;
    expect(r.release.notes.length, kMaxReleaseNotesChars);
  });

  test('a corrupted cached body does not parse', () {
    expect(GithubReleaseClient.parseCached('nope'), isNull);
    expect(GithubReleaseClient.parseCached('{"tag_name":"v1.0.0"}'), isNull);
  });
}
