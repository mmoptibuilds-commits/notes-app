import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/update/download_service.dart';
import 'package:notes/update/update_http.dart';

import 'fake_http.dart';

void main() {
  late Directory tmp;
  late FakeHttp http;
  final payload = Uint8List.fromList(List.generate(10000, (i) => i % 251));
  final goodSha = sha256.convert(payload).toString();
  const name = 'notes-1.0.1-linux-x64.tar.gz';
  final url = Uri.parse('https://example.test/dl/$name');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('notes_dl_test');
    http = FakeHttp();
  });
  tearDown(() {
    // Restore permissions a test may have removed, then delete.
    Process.runSync('chmod', ['-R', 'u+rwx', tmp.path]);
    tmp.deleteSync(recursive: true);
  });

  DownloadService svc({FreeSpaceProbe? free, Duration? idle}) =>
      DownloadService(
        http,
        freeSpace: free,
        idleTimeout: idle ?? const Duration(seconds: 5),
      );

  Future<File> run(
    DownloadService s, {
    String? sha,
    int? size,
    CancelToken? cancel,
    void Function(int, int)? onProgress,
    String filename = name,
    Directory? dir,
  }) => s.download(
    url: url,
    dir: dir ?? Directory('${tmp.path}/updates'),
    filename: filename,
    sha256Hex: sha ?? goodSha,
    size: size ?? payload.length,
    cancel: cancel,
    onProgress: onProgress,
  );

  Matcher fails(DownloadFailure kind) =>
      throwsA(isA<DownloadException>().having((e) => e.kind, 'kind', kind));

  List<String> files() =>
      Directory('${tmp.path}/updates')
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toList();

  test(
    'streams, reports progress, and renames only after verification',
    () async {
      http.on(
        url.toString(),
        FakeReply(
          200,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': '${payload.length}',
          },
          chunks: [payload.sublist(0, 4000), payload.sublist(4000)],
        ),
      );
      final progress = <int>[];
      final f = await run(svc(), onProgress: (r, t) => progress.add(r));
      expect(f.readAsBytesSync(), payload);
      expect(progress, [4000, 10000]);
      expect(files(), [name]); // no .part left behind
      expect(http.requests.single.headers['Accept-Encoding'], 'identity');
    },
  );

  test('follows an https redirect to the file host', () async {
    http.on(
      url.toString(),
      FakeReply(302, headers: {'location': 'https://objects.example.test/f'}),
    );
    http.on(
      'https://objects.example.test/f',
      FakeReply(
        200,
        body: payload,
        headers: {'content-type': 'application/octet-stream'},
      ),
    );
    await run(svc());
    expect(http.requests, hasLength(2));
  });

  test('a checksum mismatch discards everything', () async {
    http.on(url.toString(), FakeReply(200, body: payload));
    await expectLater(
      run(svc(), sha: sha64('0')),
      fails(DownloadFailure.checksumMismatch),
    );
    expect(files(), isEmpty);
  });

  test('a file larger than declared is aborted while streaming', () async {
    http.on(
      url.toString(),
      FakeReply(200, chunks: [payload.sublist(0, 6000), payload.sublist(6000)]),
    );
    await expectLater(
      run(svc(), size: 8000),
      fails(DownloadFailure.sizeMismatch),
    );
    expect(files(), isEmpty);
  });

  test('a declared content-length that differs is refused up front', () async {
    http.on(
      url.toString(),
      FakeReply(200, body: payload, headers: {'content-length': '99999'}),
    );
    await expectLater(run(svc()), fails(DownloadFailure.sizeMismatch));
    expect(files(), isEmpty);
  });

  test('a connection reset mid-download is an interruption', () async {
    http.on(
      url.toString(),
      FakeReply(
        200,
        chunks: [payload.sublist(0, 3000)],
        streamError: const SocketException('reset'),
      ),
    );
    await expectLater(run(svc()), fails(DownloadFailure.interrupted));
    expect(files(), isEmpty);
  });

  test('a download that ends early is an interruption', () async {
    http.on(url.toString(), FakeReply(200, body: payload.sublist(0, 5000)));
    await expectLater(run(svc()), fails(DownloadFailure.interrupted));
    expect(files(), isEmpty);
  });

  test('cancelling mid-stream deletes the partial file', () async {
    http.on(
      url.toString(),
      FakeReply(
        200,
        chunks: [
          payload.sublist(0, 2000),
          payload.sublist(2000, 4000),
          payload.sublist(4000),
        ],
      ),
    );
    final token = CancelToken();
    await expectLater(
      run(svc(), cancel: token, onProgress: (r, t) => token.cancel()),
      fails(DownloadFailure.cancelled),
    );
    expect(files(), isEmpty);
  });

  test(
    'a token cancelled before the start never touches the network',
    () async {
      final token = CancelToken()..cancel();
      await expectLater(
        run(svc(), cancel: token),
        fails(DownloadFailure.cancelled),
      );
      expect(http.requests, isEmpty);
    },
  );

  test('insufficient free space is reported before any request', () async {
    await expectLater(
      run(svc(free: (_) async => 5000)),
      fails(DownloadFailure.diskSpace),
    );
    expect(http.requests, isEmpty);
  });

  test('unknown free space does not block the download', () async {
    http.on(url.toString(), FakeReply(200, body: payload));
    await run(svc(free: (_) async => null));
  });

  test('plenty of free space passes', () async {
    http.on(url.toString(), FakeReply(200, body: payload));
    await run(svc(free: (_) async => 1 << 40));
  });

  test('permission denied on the update directory', () async {
    final locked = Directory('${tmp.path}/locked')..createSync();
    Process.runSync('chmod', ['500', locked.path]);
    // Skip when running as a user that ignores permissions (root).
    if (Directory('${locked.path}/x').existsSync() || _canWrite(locked.path)) {
      markTestSkipped('permissions are not enforced for this user');
      return;
    }
    http.on(url.toString(), FakeReply(200, body: payload));
    await expectLater(
      run(svc(), dir: Directory('${locked.path}/updates')),
      fails(DownloadFailure.permission),
    );
  });

  test('a web page instead of a file is refused', () async {
    http.on(
      url.toString(),
      FakeReply(200, body: payload, headers: {'content-type': 'text/html'}),
    );
    await expectLater(run(svc()), fails(DownloadFailure.contentType));
    http.replace(
      url.toString(),
      FakeReply(
        200,
        body: payload,
        headers: {'content-type': 'application/json'},
      ),
    );
    await expectLater(run(svc()), fails(DownloadFailure.contentType));
  });

  test('HTTP errors and offline are classified', () async {
    http.on(url.toString(), FakeReply(404));
    await expectLater(run(svc()), fails(DownloadFailure.http));
    http.replace(
      url.toString(),
      FakeReply(0, error: const UpdateOfflineException()),
    );
    await expectLater(run(svc()), fails(DownloadFailure.offline));
    http.replace(
      url.toString(),
      FakeReply(302, headers: {'location': 'http://plain.example/x'}),
    );
    await expectLater(run(svc()), fails(DownloadFailure.http));
  });

  test('a stalled stream times out as an interruption', () async {
    final stalled = _StallingHttp(payload.sublist(0, 100));
    final s = DownloadService(
      stalled,
      idleTimeout: const Duration(milliseconds: 100),
    );
    await expectLater(
      s.download(
        url: url,
        dir: Directory('${tmp.path}/updates'),
        filename: name,
        sha256Hex: goodSha,
        size: payload.length,
      ),
      fails(DownloadFailure.interrupted),
    );
    expect(files(), isEmpty);
  });

  test('an earlier verified download is reused without a request', () async {
    http.on(url.toString(), FakeReply(200, body: payload));
    await run(svc());
    http.requests.clear();
    final f = await run(svc());
    expect(f.readAsBytesSync(), payload);
    expect(http.requests, isEmpty);
  });

  test('an earlier file that no longer verifies is replaced', () async {
    Directory('${tmp.path}/updates').createSync();
    File('${tmp.path}/updates/$name').writeAsBytesSync([1, 2, 3]);
    http.on(url.toString(), FakeReply(200, body: payload));
    final f = await run(svc());
    expect(f.readAsBytesSync(), payload);
  });

  test('file names that could escape the directory are refused', () async {
    for (final bad in [
      '../x.tar.gz',
      'a/b',
      '',
      '.hidden',
      'a b',
      'x\n.tar.gz',
    ]) {
      await expectLater(
        run(svc(), filename: bad),
        fails(DownloadFailure.unsafeName),
      );
    }
  });

  test('cleanUpdateDir removes partials and old artifacts only', () async {
    final d = Directory('${tmp.path}/updates')..createSync();
    for (final n in [
      'notes-1.0.0-linux-x64.tar.gz',
      'notes-1.0.1-linux-x64.tar.gz',
      'notes-1.0.1-android-arm64.apk.part',
      'notes-1.0.0-android-arm64.apk',
      'pending.json',
    ]) {
      File('${d.path}/$n').writeAsStringSync('x');
    }
    await cleanUpdateDir(d, keep: 'notes-1.0.1-linux-x64.tar.gz');
    expect(files()..sort(), ['notes-1.0.1-linux-x64.tar.gz', 'pending.json']);
    await cleanUpdateDir(Directory('${tmp.path}/missing'));
  });

  test('dfFreeSpace reports a positive size for a real directory', () async {
    if (!Platform.isLinux) return;
    expect(await dfFreeSpace(tmp.path), greaterThan(0));
    expect(await dfFreeSpace('${tmp.path}/does/not/exist'), isNull);
  });
}

String sha64(String c) => c * 64;

bool _canWrite(String dir) {
  try {
    File('$dir/probe').writeAsStringSync('x');
    File('$dir/probe').deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Delivers one chunk and then never anything more.
class _StallingHttp implements UpdateHttp {
  _StallingHttp(this.chunk);
  final List<int> chunk;

  @override
  Future<UpdateResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    final c = StreamController<List<int>>()..add(chunk);
    return UpdateResponse(status: 200, headers: const {}, body: c.stream);
  }
}
