import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/ids.dart';
import '../../data/note_repository.dart';
import '../../data/models.dart';
import '../../importer/notes_export.dart';
import 'cloud_api.dart';
import 'cloud_login_launcher.dart';
import 'cloud_sync_engine.dart';
import 'record_digest.dart';

enum CloudPhase { unavailable, off, signedOut, signedIn, uploading, ready }

class CloudStatus {
  const CloudStatus({
    required this.phase,
    this.syncing = false,
    this.lastSyncAt,
    this.lastError,
    this.pendingRows = 0,
    this.uploadProgress = const CloudSyncProgress(),
    this.joinProgress = const CloudSyncProgress(),
  });
  final CloudPhase phase;
  final bool syncing;
  final DateTime? lastSyncAt;
  final String? lastError;
  final int pendingRows;
  final CloudSyncProgress uploadProgress, joinProgress;
}

class VerifiedBackup {
  const VerifiedBackup(this.path, this.notes, this.folders, this.attachments);
  final String path;
  final int notes, folders, attachments;
}

class JoinReport {
  const JoinReport({
    required this.identical,
    required this.onlyHere,
    required this.onlyThere,
    required this.differing,
    required this.missingAttachments,
    required this.folderReferenceErrors,
  });
  final int identical,
      onlyHere,
      onlyThere,
      differing,
      missingAttachments,
      folderReferenceErrors;
  bool get exact =>
      onlyHere == 0 &&
      onlyThere == 0 &&
      differing == 0 &&
      missingAttachments == 0 &&
      folderReferenceErrors == 0;
}

/// Cloud sync application service. It deliberately catches sync failures so
/// network availability never affects local saves or UI callbacks.
class CloudService extends ChangeNotifier {
  CloudService({
    required this.repo,
    required this.api,
    required this.sessions,
    required this.dataDir,
    required this.deviceName,
    required this.loginLauncher,
    required this.unavailable,
  }) : engine = CloudSyncEngine(repo, api) {
    _active = repo.db.getMeta('cloud.state') == 'on';
  }
  final NoteRepository repo;
  final CloudApi api;
  final CloudSessionStore sessions;
  final String dataDir, deviceName;
  final CloudLoginLauncher? loginLauncher;
  final bool unavailable;
  final CloudSyncEngine engine;
  Timer? _poll, _debounce, _retry;
  int _failures = 0;
  DateTime? _lastNeonBackstop;
  bool _running = false, _syncing = false, _active = false, _uploading = false;
  bool _signedIn = false;
  DateTime? _lastSync;
  String? _lastError;
  CloudPhase get phase => unavailable
      ? CloudPhase.unavailable
      : !_active
      ? CloudPhase.off
      : !_signedIn
      ? CloudPhase.signedOut
      : _uploading
      ? CloudPhase.uploading
      : (_lastSync == null ? CloudPhase.signedIn : CloudPhase.ready);
  CloudStatus get status => CloudStatus(
    phase: phase,
    syncing: _syncing,
    lastSyncAt: _lastSync,
    lastError: _lastError,
    pendingRows: _pendingCount,
    uploadProgress: engine.progress,
  );
  bool get active => _active;
  int get _pendingCount => repo
      .cloudRecordsSince(
        int.tryParse(repo.db.getMeta('cloud.push_seq') ?? '') ?? 0,
        limit: 10000,
      )
      .length;

  Future<void> setActive(bool value) async {
    _active = value;
    repo.db.transaction(
      () => repo.db.setMeta('cloud.state', value ? 'on' : 'off'),
    );
    if (value) {
      await start();
    } else {
      await stop();
    }
    notifyListeners();
  }

  Future<void> signIn() async {
    if (unavailable) {
      throw const CloudApiException(
        CloudErrorKind.network,
        'Cloud sync is unavailable in this build.',
      );
    }
    final launcher = loginLauncher;
    if (launcher == null) {
      throw const CloudApiException(
        CloudErrorKind.network,
        'Sign-in is unavailable on this platform.',
      );
    }
    final verifier = _base64Url(randomBytes(32));
    final challenge = _base64Url(sha256.convert(utf8.encode(verifier)).bytes);
    final state = _base64Url(randomBytes(24));
    final result = await launcher.login(
      (redirect) => Uri.parse('$_baseUrl/v1/auth/start').replace(
        queryParameters: {
          'challenge': challenge,
          'redirect': redirect,
          'state': state,
          'name': deviceName,
        },
      ),
    );
    if (result.state != state) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'Sign-in state did not match.',
      );
    }
    await api.authToken(result.code, verifier);
    _signedIn = true;
    await setActive(true);
  }

  String get _baseUrl =>
      api is HttpCloudApi ? (api as HttpCloudApi).baseUrl.toString() : '';

  Future<void> signOut() async {
    try {
      await api.logout();
    } on Object {
      // A failed logout still clears local credentials below.
    }
    await sessions.write(null);
    _signedIn = false;
    await setActive(false);
  }

  Future<Map<String, Object?>> libraryInfo() => api.library();

  Future<VerifiedBackup> createVerifiedBackup() async {
    final json = exportAll(repo);
    final parsed = parseExport(json);
    if (parsed.notes.length != repo.db.select('SELECT id FROM notes').length ||
        parsed.folders.length !=
            repo.db.select('SELECT id FROM folders').length ||
        parsed.attachments.length !=
            repo.db
                .select('SELECT hash FROM attachments WHERE data IS NOT NULL')
                .length) {
      throw StateError('Backup verification failed.');
    }
    for (final n in parsed.notes) {
      final current = repo.getRecord(n.id);
      if (current == null || recordDigest(current) != recordDigest(n)) {
        throw StateError('Backup verification failed.');
      }
    }
    for (final f in parsed.folders) {
      final current = repo.getFolderRecord(f.id);
      if (current == null || recordDigest(current) != recordDigest(f)) {
        throw StateError('Backup verification failed.');
      }
    }
    for (final a in parsed.attachments) {
      if (sha256.convert(a.data).toString() != a.hash) {
        throw StateError('Backup verification failed.');
      }
    }
    final dir = Directory(p.join(dataDir, 'backups'));
    await dir.create(recursive: true);
    final file = File(
      p.join(
        dir.path,
        'cloud-${DateTime.now().toUtc().millisecondsSinceEpoch}.notes-export',
      ),
    );
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(file.path);
    final read = parseExport(await file.readAsString());
    if (read.notes.length != parsed.notes.length ||
        read.folders.length != parsed.folders.length ||
        read.attachments.length != parsed.attachments.length) {
      await file.delete();
      throw StateError('Backup read-back verification failed.');
    }
    return VerifiedBackup(
      file.path,
      read.notes.length,
      read.folders.length,
      read.attachments.length,
    );
  }

  Future<void> uploadLibrary(
    VerifiedBackup backup, {
    void Function(CloudSyncProgress)? onProgress,
  }) async {
    if (!File(backup.path).existsSync()) {
      throw StateError('A verified backup is required.');
    }
    final verified = parseExport(await File(backup.path).readAsString());
    if (verified.notes.length != backup.notes ||
        verified.folders.length != backup.folders ||
        verified.attachments.length != backup.attachments) {
      throw StateError('The verified backup has changed.');
    }
    for (final note in verified.notes) {
      final current = repo.getRecord(note.id);
      if (current == null || recordDigest(current) != recordDigest(note)) {
        throw StateError('The library changed after backup verification.');
      }
    }
    for (final folder in verified.folders) {
      final current = repo.getFolderRecord(folder.id);
      if (current == null || recordDigest(current) != recordDigest(folder)) {
        throw StateError('The library changed after backup verification.');
      }
    }
    _uploading = true;
    notifyListeners();
    try {
      String id;
      final linked = repo.db.getMeta('cloud.library_id');
      if (linked != null) {
        final existing = await api.library();
        if (existing['uploaderDeviceId'] != repo.db.deviceId) {
          throw StateError('This device cannot resume the library upload.');
        }
        id = existing['libraryId'] as String;
        if (existing['state'] == 'ready') {
          _lastSync = DateTime.now();
          _lastError = null;
          return;
        }
        if (existing['state'] != 'uploading') {
          throw StateError('The cloud library is not ready for upload.');
        }
      } else {
        final init = await api.initLibrary();
        id = init['libraryId'] as String;
      }
      repo.db.transaction(() => repo.db.setMeta('cloud.library_id', id));
      final hashes = verified.attachments.map((a) => a.hash).toList();
      final blobState = await api.checkBlobs(hashes);
      for (final attachment in verified.attachments) {
        if (!blobState.missing.contains(attachment.hash) &&
            !blobState.partial.containsKey(attachment.hash)) {
          continue;
        }
        var offset = blobState.partial[attachment.hash] ?? 0;
        while (offset < attachment.size) {
          final end = (offset + 96 * 1024).clamp(0, attachment.size);
          final bytes = Uint8List.fromList(
            attachment.data.sublist(offset, end),
          );
          final next = await api.putBlobChunk(
            attachment.hash,
            offset,
            attachment.size,
            attachment.mime,
            bytes,
          );
          if (next <= offset && next < attachment.size) {
            throw const CloudApiException(
              CloudErrorKind.network,
              'Attachment upload did not advance.',
            );
          }
          offset = next;
        }
      }
      final total = _pendingCount;
      var done = 0;
      for (final kind in ['folder', 'note']) {
        final rows = repo
            .cloudRecordsSince(0, limit: 10000)
            .where((r) => r.kind == kind)
            .where((r) {
              final rowId = switch (r.record) {
                NoteRecord n => n.id,
                FolderRecord f => f.id,
                _ => '',
              };
              final saved = repo.db.select(
                'SELECT digest FROM cloud_notes WHERE kind=? AND id=?',
                [kind, rowId],
              );
              return saved.isEmpty ||
                  saved.first['digest'] != recordDigest(r.record);
            })
            .toList();
        final batches = _boundedUploadBatches(rows);
        for (final batch in batches) {
          final push = [
            for (final r in batch)
              () {
                final row = switch (r.record) {
                  NoteRecord n => n.toJson(),
                  FolderRecord f => f.toJson(),
                  _ => throw StateError('bad record'),
                };
                final old = repo.db.select(
                  'SELECT rev FROM cloud_notes WHERE kind=? AND id=?',
                  [kind, row['id']],
                );
                return CloudPushItem(
                  kind,
                  row['id'] as String,
                  old.isEmpty ? 0 : old.first['rev'] as int,
                  recordDigest(row),
                  row,
                );
              }(),
          ];
          final results = await api.push(
            id,
            'upload-${repo.db.deviceId}-${batch.first.seq}',
            push,
          );
          repo.db.transaction(() {
            for (final result in results) {
              final sent = push.firstWhere((item) => item.id == result.id);
              final row = sent.row;
              repo.db.execute(
                '''INSERT INTO cloud_notes(kind,id,rev,digest,base_title,base_body,base_vv,base_hlc)
                VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET rev=excluded.rev,digest=excluded.digest,
                base_title=excluded.base_title,base_body=excluded.base_body,base_vv=excluded.base_vv,base_hlc=excluded.base_hlc''',
                [
                  kind,
                  result.id,
                  result.rev,
                  sent.digest,
                  kind == 'note' ? row['title'] : row['name'],
                  kind == 'note' ? row['body'] : null,
                  kind == 'note' ? jsonEncode(row['contentVv']) : null,
                  kind == 'note' ? row['contentHlc'] : null,
                ],
              );
            }
          });
          done += results.length;
          engine.progress = CloudSyncProgress(uploaded: done, total: total);
          onProgress?.call(engine.progress);
          notifyListeners();
        }
      }
      repo.db.transaction(
        () => repo.db.setMeta('cloud.push_seq', '${repo.db.currentSeq}'),
      );
      await api.markReady(id);
      _lastSync = DateTime.now();
      _lastError = null;
      await setActive(true);
    } catch (e) {
      _lastError = 'Upload could not finish.';
      rethrow;
    } finally {
      _uploading = false;
      notifyListeners();
    }
  }

  Future<JoinReport> inspectForJoin() async {
    final remote = <String, String>{};
    String? after;
    while (true) {
      final page = await api.manifest(after: after);
      for (final x in page) {
        remote['${x.kind}:${x.id}'] = x.digest;
      }
      if (page.length < 500) {
        break;
      }
      after = '${page.last.kind}:${page.last.id}';
    }
    final local = <String, String>{
      for (final r in repo.cloudRecordsSince(-1, limit: 100000))
        '${r.kind}:${(r.record as dynamic).id}': recordDigest(r.record),
    };
    var same = 0, different = 0, here = 0, there = 0;
    for (final e in local.entries) {
      if (!remote.containsKey(e.key)) {
        here++;
      } else if (remote[e.key] == e.value) {
        same++;
      } else {
        different++;
      }
    }
    for (final key in remote.keys) {
      if (!local.containsKey(key)) there++;
    }
    final badFolders =
        repo.db.select(
              '''SELECT count(*) AS n FROM notes n LEFT JOIN folders f ON f.id=n.folder_id WHERE n.folder_id IS NOT NULL AND f.id IS NULL''',
            ).first['n']
            as int;
    final missing = await api.checkBlobs([
      for (final r in repo.db.select('SELECT hash FROM note_attachments'))
        r['hash'] as String,
    ]);
    return JoinReport(
      identical: same,
      onlyHere: here,
      onlyThere: there,
      differing: different,
      missingAttachments: missing.missing.length,
      folderReferenceErrors: badFolders,
    );
  }

  Future<void> join(JoinReport report) async {
    final isEmpty = repo.cloudRecordsSince(-1, limit: 1).isEmpty;
    if (!report.exact && !isEmpty) {
      throw StateError('The libraries do not match exactly.');
    }
    final library = await api.library();
    final id = library['libraryId'] as String;
    repo.db.transaction(() => repo.db.setMeta('cloud.library_id', id));
    // The next pull establishes remote rows and durable cursors.
    final head = await api.head();
    if (head['libraryId'] != id) {
      throw const CloudApiException(
        CloudErrorKind.libraryMismatch,
        'Cloud library changed.',
      );
    }
    await setActive(true);
    await syncNow();
  }

  Future<void> syncNow() async {
    _retry?.cancel();
    _failures = 0;
    await _runSync();
  }

  Future<void> _runSync() async {
    if (unavailable || _syncing || await sessions.read() == null) return;
    _signedIn = true;
    _syncing = true;
    notifyListeners();
    try {
      await engine.sync();
      _lastSync = DateTime.now();
      _lastNeonBackstop = _lastSync;
      _lastError = null;
    } on Object {
      _lastError = 'Cloud sync could not complete.';
      const backoff = [
        Duration(seconds: 30),
        Duration(minutes: 2),
        Duration(minutes: 10),
        Duration(minutes: 30),
      ];
      final wait = backoff[_failures.clamp(0, backoff.length - 1)];
      _failures++;
      _retry?.cancel();
      _retry = Timer(wait, () => unawaited(_runSync()));
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> start() async {
    if (unavailable || !_active || _running) return;
    _signedIn = await sessions.read() != null;
    if (!_signedIn) return;
    _running = true;
    repo.changes.addListener(_localChanged);
    await _runSync();
    _lastNeonBackstop ??= DateTime.now();
    _poll = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_pollHead()),
    );
  }

  Future<void> _pollHead() async {
    if (!_running || _syncing) return;
    try {
      final h = await api.head();
      if ((h['seq'] as int) >
              (int.tryParse(repo.db.getMeta('cloud.pull_seq') ?? '') ?? 0) ||
          _lastNeonBackstop == null ||
          DateTime.now().difference(_lastNeonBackstop!) >=
              const Duration(hours: 1)) {
        await _runSync();
      }
    } on Object {
      // Poll failures are retried on the next interval.
    }
  }

  void _localChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 20), () => unawaited(_runSync()));
  }

  Future<void> stop() async {
    _running = false;
    _poll?.cancel();
    _debounce?.cancel();
    _retry?.cancel();
    repo.changes.removeListener(_localChanged);
  }

  @override
  void dispose() {
    unawaited(stop());
    if (api is HttpCloudApi) (api as HttpCloudApi).close();
    super.dispose();
  }
}

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<List<({int seq, String kind, Object record})>> _boundedUploadBatches(
  List<({int seq, String kind, Object record})> rows,
) {
  final batches = <List<({int seq, String kind, Object record})>>[];
  var current = <({int seq, String kind, Object record})>[];
  var bytes = 0;
  for (final row in rows) {
    final json = switch (row.record) {
      NoteRecord note => note.toJson(),
      FolderRecord folder => folder.toJson(),
      _ => const <String, Object?>{},
    };
    final size = utf8.encode(jsonEncode(json)).length + 128;
    if (size > 240 * 1024) {
      throw const CloudApiException(
        CloudErrorKind.malformed,
        'A record is too large to upload.',
      );
    }
    if (current.isNotEmpty &&
        (current.length >= 50 || bytes + size > 240 * 1024)) {
      batches.add(current);
      current = <({int seq, String kind, Object record})>[];
      bytes = 0;
    }
    current.add(row);
    bytes += size;
  }
  if (current.isNotEmpty) batches.add(current);
  return batches;
}
