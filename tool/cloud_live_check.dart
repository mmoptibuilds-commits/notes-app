import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:notes/data/app_database.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/platform/cloud_login.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/sync/cloud/record_digest.dart';

/// Exercises the client stack against the test-build Worker.
///
/// Usage: `dart run tool/cloud_live_check.dart <base-url>`
/// Output is deliberately limited to counts and pass/fail markers.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run tool/cloud_live_check.dart <base-url>');
    exitCode = 64;
    return;
  }
  final baseUrl = Uri.tryParse(arguments.single);
  if (baseUrl == null ||
      !baseUrl.hasAuthority ||
      (baseUrl.scheme != 'https' &&
          !(baseUrl.scheme == 'http' &&
              (baseUrl.host == '127.0.0.1' || baseUrl.host == 'localhost')))) {
    stderr.writeln('FAIL invalid base URL');
    exitCode = 64;
    return;
  }

  final temporary = await Directory.systemTemp.createTemp('notes-cloud-check-');
  final dbA = AppDatabase.open(null);
  final dbB = AppDatabase.open(null);
  final sessionsA = MemoryCloudSessionStore();
  final sessionsB = MemoryCloudSessionStore();
  final apiA = HttpCloudApi(baseUrl: baseUrl, sessions: sessionsA);
  final apiB = HttpCloudApi(baseUrl: baseUrl, sessions: sessionsB);
  final repoA = NoteRepository(dbA);
  final repoB = NoteRepository(dbB);
  final launcherA = _TestWorkerLogin(baseUrl);
  final launcherB = _TestWorkerLogin(baseUrl);
  final serviceA = _service(
    repoA,
    apiA,
    sessionsA,
    temporary,
    'Check A',
    launcherA,
  );
  final serviceB = _service(
    repoB,
    apiB,
    sessionsB,
    temporary,
    'Check B',
    launcherB,
  );
  final counts = <String, int>{};
  var passed = false;
  try {
    await _reset(baseUrl);

    final otherSessions = MemoryCloudSessionStore();
    final otherApi = HttpCloudApi(baseUrl: baseUrl, sessions: otherSessions);
    try {
      await _service(
        repoA,
        otherApi,
        otherSessions,
        temporary,
        'Other account check',
        _TestWorkerLogin(baseUrl, account: 'other'),
      ).signIn();
      throw StateError('other account unexpectedly signed in');
    } on CloudLoginCancelled {
      if (await otherSessions.read() != null) rethrow;
      counts['otherAccountRejected'] = 1;
    } on CloudApiException catch (error) {
      if (error.kind != CloudErrorKind.network ||
          await otherSessions.read() != null) {
        rethrow;
      }
    } finally {
      otherApi.close();
    }

    await serviceA.signIn();
    await serviceB.signIn();
    const id = '00000000-0000-4000-8000-000000000101';
    final imageSource = repoA.putAttachment(
      Uint8List.fromList(List<int>.generate(1024, (i) => i % 251)),
      'image/test',
    );
    repoA.createNote(
      id: id,
      title: 'Live check',
      body: jsonEncode([
        {'insert': 'line one\nline two\n'},
        {
          'insert': {'image': imageSource},
        },
        {'insert': '\n'},
      ]),
    );
    final backup = await serviceA.createVerifiedBackup();
    await serviceA.uploadLibrary(backup);
    final join = await serviceB.inspectForJoin();
    await serviceB.join(join);
    counts['joinedRecords'] = repoB.cloudRecordsSince(-1, limit: 10000).length;
    if (repoB.getAttachment(imageSource) == null) {
      throw StateError('image did not download');
    }
    counts['imagesDownloaded'] = 1;

    final secondImage = repoB.putAttachment(
      Uint8List.fromList(List<int>.generate(513, (i) => (i * 7) % 253)),
      'image/test',
    );
    const imageNoteId = '00000000-0000-4000-8000-000000000102';
    repoB.createNote(
      id: imageNoteId,
      title: 'Second image',
      body: jsonEncode([
        {
          'insert': {'image': secondImage},
        },
        {'insert': '\n'},
      ]),
    );
    await serviceB.engine.sync();
    await serviceA.engine.sync();
    if (repoA.getAttachment(secondImage) == null) {
      throw StateError('second image did not download');
    }
    counts['imagesUploaded'] = 1;

    final a = repoA.getNote(id)!;
    final b = repoB.getNote(id)!;
    repoA.saveContent(
      id,
      title: a.title,
      body: jsonEncode([
        {'insert': 'A line\nline two\n'},
      ]),
      base: a.contentVv,
    );
    repoB.saveContent(
      id,
      title: b.title,
      body: jsonEncode([
        {'insert': 'line one\nB line\n'},
      ]),
      base: b.contentVv,
    );
    await Future.wait([serviceA.engine.sync(), serviceB.engine.sync()]);

    final retryRecord = repoA.getRecord(id)!;
    final retry = await apiA.push(
      (await apiA.library()).libraryId,
      'live-idempotent-retry',
      [
        CloudPushItem(
          'note',
          id,
          0,
          recordDigest(retryRecord),
          retryRecord.toJson(),
        ),
      ],
    );
    if (retry.single.unchanged != true) {
      throw StateError('idempotent retry was not recognized');
    }
    counts['idempotentRetries'] = 1;

    final mergedA = repoA.getNote(id)!;
    final mergedB = repoB.getNote(id)!;
    repoA.saveContent(
      id,
      title: 'Same line A',
      body: mergedA.body,
      base: mergedA.contentVv,
    );
    repoB.saveContent(
      id,
      title: 'Same line B',
      body: mergedB.body,
      base: mergedB.contentVv,
    );
    await Future.wait([serviceA.engine.sync(), serviceB.engine.sync()]);

    repoA.trash([id]);
    await serviceA.engine.sync();
    await serviceB.engine.sync();
    repoB.restore([id]);
    await serviceB.engine.sync();
    await serviceA.engine.sync();
    repoA.purge([imageNoteId]);
    await serviceA.engine.sync();
    await serviceB.engine.sync();

    final rowsA = _recordDigests(repoA);
    final rowsB = _recordDigests(repoB);
    if (rowsA.length != rowsB.length ||
        rowsA.entries.any((entry) => rowsB[entry.key] != entry.value)) {
      throw StateError('devices did not converge');
    }
    counts['finalRecords'] = rowsA.length;
    counts['conflictCopies'] = dbA
        .select('SELECT id FROM notes WHERE conflict_of IS NOT NULL')
        .length;
    final devices = await apiA.devices();
    counts['deviceCount'] = devices['devices'] is List
        ? (devices['devices'] as List).length
        : 0;
    passed = true;
  } catch (_) {
    // Do not print exception details: HTTP and model exceptions may contain
    // response metadata. Counts below are the only output from this tool.
    passed = false;
  } finally {
    await serviceA.stop();
    await serviceB.stop();
    serviceA.dispose();
    serviceB.dispose();
    apiA.close();
    apiB.close();
    dbA.close();
    dbB.close();
    await temporary.delete(recursive: true);
  }
  stdout.writeln('counts ${jsonEncode(counts)}');
  stdout.writeln(passed ? 'PASS cloud live check' : 'FAIL cloud live check');
  if (!passed) exitCode = 1;
}

CloudService _service(
  NoteRepository repo,
  CloudApi api,
  CloudSessionStore sessions,
  Directory directory,
  String deviceName,
  CloudLoginLauncher launcher,
) => CloudService(
  repo: repo,
  api: api,
  sessions: sessions,
  dataDir: directory.path,
  deviceName: deviceName,
  loginLauncher: launcher,
  unavailable: false,
);

Future<void> _reset(Uri baseUrl) async {
  // Reset is authenticated and the Worker enforces test-only availability.
  // Sign in briefly through the test UI to obtain the required bearer.
  final store = MemoryCloudSessionStore();
  final launcher = _TestWorkerLogin(baseUrl);
  final db = AppDatabase.open(null);
  final repo = NoteRepository(db);
  final client = HttpCloudApi(baseUrl: baseUrl, sessions: store);
  final directory = await Directory.systemTemp.createTemp('notes-cloud-reset-');
  final service = _service(repo, client, store, directory, 'Reset', launcher);
  try {
    await service.signIn();
    final session = await store.read();
    if (session == null) throw StateError('test sign-in failed');
    final reset = await _rawJson(
      baseUrl.resolve('/v1/test/reset'),
      method: 'POST',
      token: session.access,
      body: const {},
    );
    if (reset['ok'] != true) {
      throw StateError('test reset failed');
    }
    await client.logout();
  } finally {
    service.dispose();
    client.close();
    db.close();
    await directory.delete(recursive: true);
  }
}

Future<Map<String, Object?>> _rawJson(
  Uri uri, {
  required String method,
  String? token,
  Object? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('request failed');
    }
    return (jsonDecode(text) as Map).cast<String, Object?>();
  } finally {
    client.close(force: true);
  }
}

Map<String, String> _recordDigests(NoteRepository repo) => {
  for (final entry in repo.cloudRecordsSince(-1, limit: 10000))
    '${entry.kind}:${switch (entry.record) {
      NoteRecord note => note.id,
      FolderRecord folder => folder.id,
      _ => '',
    }}': recordDigest(
      entry.record,
    ),
};

class _TestWorkerLogin implements CloudLoginLauncher {
  _TestWorkerLogin(this.baseUrl, {this.account = 'owner'});
  final Uri baseUrl;
  final String account;
  @override
  Future<CloudLoginResult> login(
    Uri Function(String redirect) startUrl, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final redirect = 'http://127.0.0.1:43721/cb';
    final start = startUrl(redirect);
    final first = await _get(start).timeout(timeout);
    final linkMatch = RegExp(r'href="([^"]*account=' + account + r'[^"]*)"')
        .firstMatch(first.body);
    if (linkMatch == null) throw const CloudLoginCancelled();
    final signin = baseUrl.resolve(
      linkMatch.group(1)!.replaceAll('&amp;', '&'),
    );
    final result = await _get(signin).timeout(timeout);
    if (result.status == 403) throw const CloudLoginCancelled();
    final redirectMatch = RegExp(r'href="([^"]*code=[^"]*)"')
        .firstMatch(result.body);
    if (redirectMatch == null) throw const CloudLoginCancelled();
    final callback = Uri.parse(
      redirectMatch.group(1)!.replaceAll('&amp;', '&'),
    );
    return parseCloudLoginRedirect(callback);
  }

  Future<({int status, String body})> _get(Uri uri) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(uri)).close();
      return (
        status: response.statusCode,
        body: await utf8.decoder.bind(response).join(),
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  void cancel() {}
}
