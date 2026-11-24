import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/platform/cloud_login.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/sync/cloud/record_digest.dart';

enum CloudScenarioRole { linux, android }

/// Runs the same cloud scenario for either peer. Every wait is bounded and
/// reports its named step without including note content or credentials.
Future<void> runCloudScenario(CloudScenarioRole role, Uri worker) async {
  final dataDir = await Directory.systemTemp.createTemp('notes-cloud-device-');
  AppServices? services;
  CloudService? cloud;
  HttpCloudApi? api;
  final sessions = MemoryCloudSessionStore();
  final counts = <String, int>{};
  var activeStep = 'bootstrap';
  void pass(String name) {
    counts[name] = 1;
    // ignore: avoid_print
    print('PASS $name');
  }

  Future<void> step(String name, Future<void> Function() action) async {
    activeStep = name;
    try {
      await action();
      pass(name);
    } on Object {
      // ignore: avoid_print
      print('FAIL $name');
      rethrow;
    }
  }

  try {
    final bootstrapped = await bootstrap(dataDir: dataDir.path);
    services = bootstrapped;
    // bootstrap gives this process its real encrypted database and platform
    // key store. The scenario supplies fake HTTP login and isolated sessions.
    bootstrapped.cloud?.dispose();
    final httpApi = _DropNextPushApi(baseUrl: worker, sessions: sessions);
    api = httpApi;
    final cloudService = CloudService(
      repo: bootstrapped.notes,
      api: httpApi,
      sessions: sessions,
      dataDir: dataDir.path,
      deviceName: role == CloudScenarioRole.linux
          ? 'Linux cloud test'
          : 'Android cloud test',
      loginLauncher: _TestLogin(worker),
      unavailable: false,
    );
    cloud = cloudService;
    final repo = bootstrapped.notes;
    final side = role == CloudScenarioRole.linux ? 'L' : 'A';
    final joinedAfterMs = DateTime.now()
        .subtract(const Duration(seconds: 15))
        .millisecondsSinceEpoch;

    await step('sign in', () async {
      await cloudService.signIn();
      if (role == CloudScenarioRole.linux) {
        final session = await sessions.read();
        if (session == null) throw StateError('sign in did not create session');
        await _postJson(
          worker.resolve('/v1/test/reset'),
          session.access,
          const {},
        );
        // Give the peer a polling window to observe the empty head before this
        // role initializes the fresh library. This prevents stale readiness
        // from a previous live run being mistaken for this run's upload.
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    });

    if (role == CloudScenarioRole.linux) {
      await step('L creates and uploads initial library', () async {
        final folder = repo.createFolder('Device test folder');
        final image = repo.putAttachment(_bytes(4096, 5), 'image/test');
        repo.createNote(
          id: _n1,
          title: 'Device test N1',
          body: _body(['N1 first line', 'N1 second line'], image),
          folderId: folder.id,
        );
        repo.createNote(
          id: _n2,
          title: 'Device test N2',
          body: _body(['N2 original line', 'N2 second line']),
        );
        await cloudService.uploadLibrary(
          await cloudService.createVerifiedBackup(),
        );
        if ((await cloudService.libraryInfo()).state != 'ready') {
          throw StateError('library did not become ready');
        }
      });
    } else {
      await step('A waits for ready and joins empty library', () async {
        await _wait('A waits for ready', () async {
          final library = await httpApi.library();
          if (library.state != 'ready') return false;
          final manifest = await httpApi.manifest();
          if (!manifest.items.any(
            (item) => item.kind == 'note' && item.id == _n1,
          )) {
            return false;
          }
          final changes = await httpApi.changes(
            library.libraryId,
            0,
            limit: 100,
          );
          final initial = changes.rows.where((row) => row.id == _n1);
          if (initial.isEmpty) return false;
          final createdAt = initial.first.row['createdAt'];
          return createdAt is int && createdAt >= joinedAfterMs;
        });
        final report = await cloudService.inspectForJoin();
        final library = await httpApi.library();
        final expected = library.notes + library.folders;
        if (report.onlyHere != 0 ||
            report.onlyThere != expected ||
            report.differing != 0 ||
            report.missingAttachments != 0 ||
            report.folderReferenceErrors != 0) {
          throw StateError(
            'empty-device join report counts: here=${report.onlyHere}, '
            'there=${report.onlyThere}, expected=$expected, '
            'differing=${report.differing}, missing=${report.missingAttachments}, '
            'folderErrors=${report.folderReferenceErrors}',
          );
        }
        await cloudService.join(report);
        await cloudService.syncNow();
        _expect(
          repo.getNote(_n1) != null && repo.getNote(_n2) != null,
          'initial notes missing',
        );
        final imageRef = _imageRef(repo.getNote(_n1)!.body);
        _expect(
          _attachmentHash(repo.getAttachment(imageRef)!) ==
              imageRef.substring(4),
          'initial image hash mismatch',
        );
        _expect(repo.listFolders().length == 1, 'initial folder missing');
      });
    }

    await _barrier(cloudService, repo, 'initial', side);

    await step('L to A edit and second image', () async {
      if (role == CloudScenarioRole.linux) {
        final n = repo.getNote(_n1)!;
        final image = repo.putAttachment(_bytes(777, 17), 'image/test');
        repo.saveContent(
          _n1,
          title: n.title,
          body: _body(['N1 edited by Linux', 'N1 second line'], image),
          base: n.contentVv,
        );
        await cloudService.syncNow();
      } else {
        await _waitForRecord(
          cloudService,
          repo,
          _n1,
          (n) => n.body.contains('N1 edited by Linux'),
        );
        _expect(
          repo.db
                  .select('SELECT hash FROM attachments WHERE data IS NOT NULL')
                  .length >=
              2,
          'second image missing',
        );
      }
    });
    await _barrier(cloudService, repo, 'l-to-a', side);

    await step('A to L note with image', () async {
      if (role == CloudScenarioRole.android) {
        final image = repo.putAttachment(_bytes(991, 29), 'image/test');
        repo.createNote(
          id: _aNote,
          title: 'Device test Android note',
          body: _body(['Created by Android'], image),
        );
        await cloudService.syncNow();
      } else {
        await _waitForRecord(cloudService, repo, _aNote, (_) => true);
        final note = repo.getNote(_aNote)!;
        final imageRef = _imageRef(note.body);
        _expect(
          _attachmentHash(repo.getAttachment(imageRef)!) ==
              imageRef.substring(4),
          'Android image hash mismatch',
        );
      }
    });
    await _barrier(cloudService, repo, 'a-to-l', side);

    await step('offline different and same line edits', () async {
      await cloudService.setEnabled(false);
      final current1 = repo.getNote(_n1)!;
      final current2 = repo.getNote(_n2)!;
      if (role == CloudScenarioRole.linux) {
        repo.saveContent(
          _n1,
          title: current1.title,
          body: _body(['N1 Linux offline line', 'N1 second line']),
          base: current1.contentVv,
        );
        repo.saveContent(
          _n2,
          title: current2.title,
          body: _body(['N2 Linux offline line', 'N2 second line']),
          base: current2.contentVv,
        );
        repo.setPinned([_n1], true);
        repo.createFolder('Linux offline folder');
      } else {
        repo.saveContent(
          _n1,
          title: current1.title,
          body: _body(['N1 edited by Linux', 'N1 Android offline line']),
          base: current1.contentVv,
        );
        repo.saveContent(
          _n2,
          title: current2.title,
          body: _body(['N2 Android offline line', 'N2 second line']),
          base: current2.contentVv,
        );
      }
    });
    await step('reconnect merge and Review edits', () async {
      await cloudService.setEnabled(true);
      await cloudService.syncNow();
      // A peer can reconnect first and briefly see its own digest echoed by
      // the server. Wait for both reconnect markers before judging the merge.
      await _barrier(cloudService, repo, 'reconnect', side);
      await _wait('reconnect convergence', () async {
        await cloudService.syncNow();
        return _sameDigests(repo, await _remoteDigestSnapshot(cloudService));
      });
      final n1 = repo.getNote(_n1)!;
      final linuxLine = n1.body.contains('N1 Linux offline line');
      final androidLine = n1.body.contains('N1 Android offline line');
      _expect(
        linuxLine && androidLine,
        'N1 merge counts: linux=$linuxLine android=$androidLine '
        'review=${n1.reviewEditsCount} copies=${repo.listNotes(scope: NoteScope.conflicts).where((n) => n.conflictOf == _n1).length}',
      );
      _expect(
        repo
            .listNotes(scope: NoteScope.conflicts)
            .where((n) => n.conflictOf == _n1)
            .isEmpty,
        'N1 has a conflict copy',
      );
      for (final id in [_n2]) {
        final main = repo.getNote(id)!;
        _expect(main.reviewEditsCount == 1, 'Review edits count mismatch');
        _expect(
          repo
                  .listNotes(scope: NoteScope.conflicts)
                  .where((n) => n.conflictOf == id)
                  .length ==
              1,
          'N2 conflict copy count mismatch',
        );
      }
      _expect(repo.getNote(_n1)!.pinned, 'pin did not converge');
      _expect(
        repo.listFolders().any((f) => f.name == 'Linux offline folder'),
        'offline folder did not converge',
      );
    });
    await _barrier(cloudService, repo, 'offline-merged', side);

    await step('simultaneous clean line merge', () async {
      final id = _simNote;
      if (role == CloudScenarioRole.linux) {
        repo.createNote(
          id: id,
          title: 'Simultaneous edit',
          body: _body(['base alpha', 'base beta']),
        );
        await cloudService.syncNow();
      } else {
        await _waitForRecord(cloudService, repo, id, (_) => true);
      }
      await _barrier(cloudService, repo, 'simultaneous-base', side);
      final base = repo.getNote(id)!;
      repo.saveContent(
        id,
        title: base.title,
        body: _body(
          role == CloudScenarioRole.linux
              ? ['Linux alpha', 'base beta']
              : ['base alpha', 'Android beta'],
        ),
        base: base.contentVv,
      );
      await Future.wait([cloudService.syncNow()]);
      await _wait('simultaneous settle', () async {
        await cloudService.syncNow();
        final n = repo.getNote(id)!;
        return n.body.contains('Linux alpha') &&
            n.body.contains('Android beta') &&
            _sameDigests(repo, await _remoteDigestSnapshot(cloudService));
      });
      _expect(
        repo
            .listNotes(scope: NoteScope.conflicts)
            .where((n) => n.conflictOf == id)
            .isEmpty,
        'simultaneous edit created conflict copy',
      );
    });

    await step('committed response retry is idempotent', () async {
      if (role == CloudScenarioRole.android) {
        final n = repo.getNote(_aNote)!;
        repo.saveContent(
          _aNote,
          title: n.title,
          body: _body(['Android retry edit']),
          base: n.contentVv,
        );
        httpApi.dropNextPushResponse = true;
        await cloudService.syncNow();
        await cloudService.syncNow();
      }
      await _wait('retry convergence', () async {
        await cloudService.syncNow();
        return _sameDigests(repo, await _remoteDigestSnapshot(cloudService));
      });
      _expect(_recordCount(repo, _aNote) == 1, 'retry duplicated note');
    });
    await _barrier(cloudService, repo, 'retry-done', side);

    await step('trash restore purge and metadata states', () async {
      if (role == CloudScenarioRole.android) {
        repo.trash([_n1]);
        await cloudService.syncNow();
      } else {
        await _wait('N1 arrives in Trash', () async {
          await cloudService.syncNow();
          return repo.getNote(_n1)?.isTrashed ?? false;
        });
        repo.restore([_n1]);
        repo.setArchived([_aNote], true);
        await cloudService.syncNow();
      }
      if (role == CloudScenarioRole.android) {
        await _wait('N1 restored and archive propagated', () async {
          await cloudService.syncNow();
          return repo.getNote(_n1)?.isTrashed == false &&
              repo.getNote(_aNote)?.archived == true;
        });
        repo.setArchived([_aNote], false);
        repo.setPinned([_aNote], true);
        await cloudService.syncNow();
      } else {
        await _wait('pin propagated', () async {
          await cloudService.syncNow();
          return repo.getNote(_aNote)?.pinned == true;
        });
      }
      if (role == CloudScenarioRole.linux) {
        repo.purge([_n2]);
        await cloudService.syncNow();
      } else {
        await _wait('N2 tombstone and metadata', () async {
          await cloudService.syncNow();
          return repo.getRecord(_n2)?.purged == true &&
              repo.getNote(_aNote)?.archived == false;
        });
        _expect(repo.getRecord(_n2)!.purged, 'N2 tombstone missing');
        _expect(
          repo
                  .listNotes(scope: NoteScope.conflicts)
                  .where((n) => n.conflictOf == _n2)
                  .length ==
              1,
          'conflict handling changed',
        );
      }
      await _barrier(cloud!, repo, 'states-done', side);
    });

    await step('final digest summary and sign out', () async {
      await _wait('final convergence', () async {
        await cloudService.syncNow();
        return _sameDigests(repo, await _remoteDigestSnapshot(cloudService));
      });
      final all = _digests(repo);
      final summary = sha256
          .convert(
            utf8.encode(
              (all.keys.toList()..sort()).map((k) => '$k:${all[k]}').join('|'),
            ),
          )
          .toString();
      await _publishBarrier(cloud!, repo, 'final-$side', summary);
      final peerSummary = 'final-${side == 'L' ? 'A' : 'L'}';
      await _wait('final digest summary', () async {
        await cloudService.syncNow();
        final peer = repo
            .listNotes(scope: NoteScope.active)
            .where((n) => n.title == '~barrier:$peerSummary');
        if (peer.isEmpty) return false;
        return repo.getNote(peer.first.id)!.body.contains(summary);
      });
      await cloudService.signOut();
      // ignore: avoid_print
      print('COUNTS ${jsonEncode(counts)} records=${all.length}');
    });
  } catch (_) {
    // ignore: avoid_print
    print('FAIL scenario step=$activeStep');
    rethrow;
  } finally {
    final activeCloud = cloud;
    if (activeCloud != null) {
      try {
        await activeCloud.signOut();
      } on Object {
        // A failed logout is retried by the enclosing finally on every role.
      }
      await activeCloud.stop();
      activeCloud.dispose();
    }
    api?.close();
    services?.close();
    if (dataDir.existsSync()) await dataDir.delete(recursive: true);
  }
}

const _n1 = '00000000-0000-4000-8000-000000000111';
const _n2 = '00000000-0000-4000-8000-000000000112';
const _aNote = '00000000-0000-4000-8000-000000000113';
const _simNote = '00000000-0000-4000-8000-000000000114';

String _body(List<String> lines, [String? image]) => jsonEncode([
  for (final line in lines) {'insert': '$line\n'},
  if (image != null)
    {
      'insert': {'image': image},
    },
  {'insert': '\n'},
]);

Uint8List _bytes(int size, int seed) =>
    Uint8List.fromList(List.generate(size, (i) => (i * 19 + seed) % 251));

String _imageRef(String body) {
  final decoded = jsonDecode(body) as List;
  for (final op in decoded) {
    final insert = op['insert'];
    if (insert is Map && insert['image'] is String) {
      return insert['image'] as String;
    }
  }
  throw StateError('image embed missing');
}

String _attachmentHash(Uint8List bytes) => sha256.convert(bytes).toString();

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

int _recordCount(NoteRepository repo, String id) => repo
    .cloudRecordsSince(-1, limit: 10000)
    .where(
      (r) => switch (r.record) {
        NoteRecord n => n.id == id,
        FolderRecord f => f.id == id,
        _ => false,
      },
    )
    .length;

bool _sameDigests(NoteRepository repo, Map<String, String> remote) {
  final local = _digests(repo);
  return local.length == remote.length &&
      local.entries.every((e) => remote[e.key] == e.value);
}

Future<Map<String, String>> _remoteDigestSnapshot(CloudService cloud) async {
  final result = <String, String>{};
  var cursor = 0;
  while (true) {
    final page = await cloud.api.changes(
      (await cloud.api.library()).libraryId,
      cursor,
      limit: 100,
    );
    for (final row in page.rows) {
      result['${row.kind}:${row.id}'] = row.digest;
    }
    if (!page.more) break;
    cursor = page.next;
  }
  return result;
}

Future<void> _wait(String name, Future<bool> Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(end)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  throw StateError('Timed out waiting for $name.');
}

Future<void> _waitForRecord(
  CloudService cloud,
  NoteRepository repo,
  String id,
  bool Function(Note) predicate,
) => _wait('record available', () async {
  await cloud.syncNow();
  final note = repo.getNote(id);
  return note != null && predicate(note);
});

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> _publishBarrier(
  CloudService cloud,
  NoteRepository repo,
  String name,
  String body,
) async {
  final suffix = sha256.convert(utf8.encode(name)).toString().substring(0, 12);
  final id = '00000000-0000-4000-8000-$suffix';
  final existing = repo.getNote(id);
  if (existing == null) {
    repo.createNote(id: id, title: '~barrier:$name', body: _body([body]));
  } else {
    repo.saveContent(
      id,
      title: '~barrier:$name',
      body: _body([body]),
      base: existing.contentVv,
    );
  }
  await cloud.syncNow();
}

Future<void> _barrier(
  CloudService cloud,
  NoteRepository repo,
  String name,
  String side,
) async {
  await _publishBarrier(cloud, repo, '$name-$side', 'ready');
  await _waitForBarrier(cloud, repo, '$name-${side == 'L' ? 'A' : 'L'}');
}

Future<void> _waitForBarrier(
  CloudService cloud,
  NoteRepository repo,
  String name,
) => _wait('barrier $name', () async {
  await cloud.syncNow();
  return repo
      .listNotes(scope: NoteScope.active)
      .any((n) => n.title == '~barrier:$name');
});

class _DropNextPushApi extends HttpCloudApi {
  _DropNextPushApi({required super.baseUrl, required super.sessions});
  bool dropNextPushResponse = false;
  @override
  Future<List<CloudPushResult>> push(
    String libraryId,
    String batchId,
    List<CloudPushItem> rows,
  ) async {
    final result = await super.push(libraryId, batchId, rows);
    if (dropNextPushResponse) {
      dropNextPushResponse = false;
      throw const CloudApiException(
        CloudErrorKind.network,
        'simulated lost response',
      );
    }
    return result;
  }
}

class _TestLogin implements CloudLoginLauncher {
  _TestLogin(this.url);
  final Uri url;
  @override
  Future<CloudLoginResult> login(
    Uri Function(String) startUrl, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final start = await _get(startUrl('http://127.0.0.1:43721/cb'));
    final match = RegExp('href="([^"]*account=owner[^"]*)"').firstMatch(start);
    if (match == null) throw const CloudLoginCancelled();
    final signed = await _get(
      url.resolve(match.group(1)!.replaceAll('&amp;', '&')),
    );
    final callback = RegExp('href="([^"]*code=[^"]*)"').firstMatch(signed);
    if (callback == null) throw const CloudLoginCancelled();
    return parseCloudLoginRedirect(
      Uri.parse(callback.group(1)!.replaceAll('&amp;', '&')),
    );
  }

  Future<String> _get(Uri uri) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(uri)).close();
      return await utf8.decoder.bind(response).join();
    } finally {
      client.close(force: true);
    }
  }

  @override
  void cancel() {}
}

Future<void> _postJson(Uri uri, String token, Object body) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final response = await req.close();
    await response.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('test library reset failed');
    }
  } finally {
    client.close(force: true);
  }
}
