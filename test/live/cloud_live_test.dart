import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/platform/cloud_login.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/sync/cloud/record_digest.dart';

void main() {
  final configuredUrl = Platform.environment['CLOUD_LIVE_URL'];
  final baseUrl = configuredUrl == null ? null : Uri.tryParse(configuredUrl);
  test(
    'live Worker sync flow',
    () async {
      final url = baseUrl!;
      final temporary = await Directory.systemTemp.createTemp(
        'notes-cloud-live-',
      );
      final dbA = AppDatabase.open(null), dbB = AppDatabase.open(null);
      final storeA = MemoryCloudSessionStore(),
          storeB = MemoryCloudSessionStore();
      final apiA = HttpCloudApi(baseUrl: url, sessions: storeA),
          apiB = HttpCloudApi(baseUrl: url, sessions: storeB);
      final repoA = NoteRepository(dbA), repoB = NoteRepository(dbB);
      final serviceA = _service(
        repoA,
        apiA,
        storeA,
        temporary,
        'Device A',
        _TestLogin(url),
      );
      final serviceB = _service(
        repoB,
        apiB,
        storeB,
        temporary,
        'Device B',
        _TestLogin(url),
      );
      final counts = <String, int>{};
      try {
        await serviceA.signIn();
        final resetSession = await storeA.read();
        if (resetSession == null) throw StateError('Live sync check failed.');
        await _json(
          url.resolve('/v1/test/reset'),
          method: 'POST',
          token: resetSession.access,
          body: const {},
        );
        final otherStore = MemoryCloudSessionStore();
        final otherApi = HttpCloudApi(baseUrl: url, sessions: otherStore);
        try {
          await _service(
            repoA,
            otherApi,
            otherStore,
            temporary,
            'Other',
            _TestLogin(url, other: true),
          ).signIn();
          throw StateError('Live sync check failed.');
        } on CloudLoginCancelled {
          if (await otherStore.read() != null) {
            throw StateError('Live sync check failed.');
          }
          counts['otherAccountRejected'] = 1;
        } finally {
          otherApi.close();
        }
        await serviceA.signOut();
        await serviceA.signIn();
        await serviceB.signIn();
        const id = '00000000-0000-4000-8000-000000000101';
        final image = repoA.putAttachment(
          Uint8List.fromList(List.generate(1024, (i) => i % 251)),
          'image/test',
        );
        repoA.createNote(
          id: id,
          title: 'Live check',
          body: jsonEncode([
            {'insert': 'line one\nline two\n'},
            {
              'insert': {'image': image},
            },
            {'insert': '\n'},
          ]),
        );
        await serviceA.uploadLibrary(await serviceA.createVerifiedBackup());
        await serviceB.join(await serviceB.inspectForJoin());
        counts['joinedRecords'] = repoB
            .cloudRecordsSince(-1, limit: 10000)
            .length;
        if (repoB.getAttachment(image) == null) {
          throw StateError('Live sync check failed.');
        }
        counts['imagesDownloaded'] = 1;
        final extraImage = repoB.putAttachment(
          Uint8List.fromList(List.generate(513, (i) => (i * 7) % 253)),
          'image/test',
        );
        const imageId = '00000000-0000-4000-8000-000000000102';
        repoB.createNote(
          id: imageId,
          title: 'Image',
          body: jsonEncode([
            {
              'insert': {'image': extraImage},
            },
            {'insert': '\n'},
          ]),
        );
        await serviceB.engine.sync();
        await serviceA.engine.sync();
        if (repoA.getAttachment(extraImage) == null) {
          throw StateError('Live sync check failed.');
        }
        counts['imagesUploaded'] = 1;
        final a = repoA.getNote(id)!, b = repoB.getNote(id)!;
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
        final pushed = repoA.getRecord(id)!;
        final retry = await apiA.push(
          (await apiA.library()).libraryId,
          'live-retry',
          [CloudPushItem('note', id, 0, recordDigest(pushed), pushed.toJson())],
        );
        if (!retry.single.unchanged) {
          throw StateError('Live sync check failed.');
        }
        counts['idempotentRetries'] = 1;
        final sameA = repoA.getNote(id)!, sameB = repoB.getNote(id)!;
        repoA.saveContent(
          id,
          title: 'Same line A',
          body: sameA.body,
          base: sameA.contentVv,
        );
        repoB.saveContent(
          id,
          title: 'Same line B',
          body: sameB.body,
          base: sameB.contentVv,
        );
        await Future.wait([serviceA.engine.sync(), serviceB.engine.sync()]);
        repoA.trash([id]);
        await serviceA.engine.sync();
        await serviceB.engine.sync();
        repoB.restore([id]);
        await serviceB.engine.sync();
        await serviceA.engine.sync();
        repoA.purge([imageId]);
        await serviceA.engine.sync();
        await serviceB.engine.sync();
        final digestsA = _digests(repoA), digestsB = _digests(repoB);
        if (digestsA.length != digestsB.length ||
            digestsA.entries.any((e) => digestsB[e.key] != e.value)) {
          throw StateError('Live sync check failed.');
        }
        counts['finalRecords'] = digestsA.length;
        counts['conflictCopies'] = dbA
            .select('SELECT id FROM notes WHERE conflict_of IS NOT NULL')
            .length;
        // Logout both real test devices so repeated live checks do not consume the five-device cap.
        await serviceA.signOut();
        await serviceB.signOut();
        // Emit only aggregate values and pass/fail, never credentials or note content.
        // ignore: avoid_print
        print('counts ${jsonEncode(counts)}');
        // ignore: avoid_print
        print('PASS cloud live check');
      } catch (_) {
        // ignore: avoid_print
        print('counts ${jsonEncode(counts)}');
        // ignore: avoid_print
        print('FAIL cloud live check');
        rethrow;
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
    },
    skip: baseUrl == null
        ? 'Set CLOUD_LIVE_URL to run against the isolated test Worker.'
        : false,
  );
}

CloudService _service(
  NoteRepository repo,
  CloudApi api,
  CloudSessionStore store,
  Directory dir,
  String name,
  CloudLoginLauncher launcher,
) => CloudService(
  repo: repo,
  api: api,
  sessions: store,
  dataDir: dir.path,
  deviceName: name,
  loginLauncher: launcher,
  unavailable: false,
);

Map<String, String> _digests(NoteRepository repo) => {
  for (final e in repo.cloudRecordsSince(-1, limit: 10000))
    '${e.kind}:${switch (e.record) {
      NoteRecord n => n.id,
      FolderRecord f => f.id,
      _ => '',
    }}': recordDigest(
      e.record,
    ),
};

class _TestLogin implements CloudLoginLauncher {
  _TestLogin(this.url, {this.other = false});
  final Uri url;
  final bool other;
  @override
  Future<CloudLoginResult> login(
    Uri Function(String) startUrl, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final start = await _get(startUrl('http://127.0.0.1:43721/cb'));
    final match = RegExp(
      'href="([^"]*account=${other ? 'other' : 'owner'}[^"]*)"',
    ).firstMatch(start.body);
    if (match == null) throw const CloudLoginCancelled();
    final signed = await _get(
      url.resolve(match.group(1)!.replaceAll('&amp;', '&')),
    );
    if (signed.status == 403) throw const CloudLoginCancelled();
    final callback = RegExp('href="([^"]*code=[^"]*)"').firstMatch(signed.body);
    if (callback == null) throw const CloudLoginCancelled();
    return parseCloudLoginRedirect(
      Uri.parse(callback.group(1)!.replaceAll('&amp;', '&')),
    );
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

Future<Map<String, Object?>> _json(
  Uri uri, {
  required String method,
  required String token,
  required Object body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Live sync check failed.');
    }
    return (jsonDecode(text) as Map).cast<String, Object?>();
  } finally {
    client.close(force: true);
  }
}
