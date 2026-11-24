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
import '../../platform/cloud_login.dart';
import 'cloud_api.dart';
import 'cloud_sync_engine.dart';
import 'record_digest.dart';

enum CloudPhase {
  unavailable,
  off,
  signedOut,
  signedIn,
  uploading,
  ready,
  paused,
}

class CloudStatus {
  const CloudStatus({
    required this.phase,
    this.syncing = false,
    this.lastSyncAt,
    this.lastError,
    this.pendingRows = 0,
    this.uploadProgress = const CloudSyncProgress(),
    this.joinProgress = const CloudSyncProgress(),
    this.needsAttention = false,
  });
  final CloudPhase phase;
  final bool syncing;
  final DateTime? lastSyncAt;
  final String? lastError;
  final int pendingRows;
  final CloudSyncProgress uploadProgress, joinProgress;
  final bool needsAttention;
}

class VerifiedBackup {
  const VerifiedBackup(this.path, this.notes, this.folders, this.attachments);
  final String path;
  final int notes, folders, attachments;
}

class CloudBackupException implements Exception {
  const CloudBackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

bool _sameMap(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

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

/// Cloud sync surface for the UI: [status], [signIn], [signOut], [setEnabled],
/// [libraryInfo], [createVerifiedBackup], [uploadLibrary], [inspectForJoin],
/// [join], [syncNow], [devices], [revokeDevice], and [localSummary]. Status
/// contains the phase, syncing flag, last sync/error, pending count, upload and
/// join progress, and attention state. Account identifiers and email are never
/// retained. Sync errors never affect local saves.
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
    _enabled =
        repo.db.getMeta('cloud.enabled') == 'on' ||
        (repo.db.getMeta('cloud.enabled') == null &&
            repo.db.getMeta('cloud.state') == 'on');
    final savedSync = int.tryParse(repo.db.getMeta('cloud.last_sync_at') ?? '');
    if (savedSync != null) {
      _lastSync = DateTime.fromMillisecondsSinceEpoch(savedSync);
    }
    engine.progress = CloudSyncProgress(
      uploaded:
          int.tryParse(repo.db.getMeta('cloud.upload_progress') ?? '') ?? 0,
      total: _pendingCount,
    );
    _joinProgress = CloudSyncProgress(
      uploaded: int.tryParse(repo.db.getMeta('cloud.join_progress') ?? '') ?? 0,
    );
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
  bool _running = false, _syncing = false, _enabled = false, _uploading = false;
  bool _signedIn = false;
  DateTime? _lastSync;
  String? _lastError;
  CloudSyncProgress _joinProgress = const CloudSyncProgress();
  bool _needsAttention = false;
  bool get active =>
      !unavailable &&
      _signedIn &&
      _enabled &&
      repo.db.getMeta('cloud.library_id') != null;
  CloudPhase get phase => unavailable
      ? CloudPhase.unavailable
      : !_enabled
      ? (_signedIn
            ? CloudPhase.paused
            : repo.db.getMeta('cloud.phase') == 'signedOut'
            ? CloudPhase.signedOut
            : CloudPhase.off)
      : !_signedIn
      ? CloudPhase.signedOut
      : _uploading
      ? CloudPhase.uploading
      : repo.db.getMeta('cloud.phase') == 'uploading'
      ? CloudPhase.uploading
      : repo.db.getMeta('cloud.library_id') == null
      ? CloudPhase.signedIn
      : (_lastSync == null ? CloudPhase.signedIn : CloudPhase.ready);
  CloudStatus get status => CloudStatus(
    phase: phase,
    syncing: _syncing,
    lastSyncAt: _lastSync,
    lastError: _lastError,
    pendingRows: _pendingCount,
    uploadProgress: engine.progress,
    joinProgress: _joinProgress,
    needsAttention: _needsAttention,
  );
  int get _pendingCount => repo
      .cloudRecordsSince(
        int.tryParse(repo.db.getMeta('cloud.push_seq') ?? '') ?? 0,
        limit: 10000,
      )
      .length;

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    repo.db.transaction(() {
      repo.db.setMeta('cloud.enabled', value ? 'on' : 'off');
      repo.db.setMeta(
        'cloud.phase',
        value ? (_signedIn ? 'signedIn' : 'signedOut') : 'paused',
      );
    });
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
    repo.db.transaction(() => repo.db.setMeta('cloud.phase', 'signedIn'));
    notifyListeners();
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
    await stop();
    repo.db.transaction(() {
      repo.db.setMeta('cloud.phase', 'signedOut');
      repo.db.setMeta('cloud.enabled', 'off');
    });
    _enabled = false;
    notifyListeners();
  }

  Future<Map<String, Object?>> devices() => api.devices();
  Future<void> revokeDevice(String id) => api.revokeDevice(id);

  /// Counts only; safe for the upload confirmation screen.
  Map<String, int> localSummary() => {
    'notes':
        (repo.db.select('SELECT count(*) AS n FROM notes').first['n'] as int),
    'folders':
        (repo.db.select('SELECT count(*) AS n FROM folders').first['n'] as int),
    'images':
        (repo.db
                .select(
                  'SELECT count(*) AS n FROM attachments WHERE data IS NOT NULL',
                )
                .first['n']
            as int),
    'bytes':
        (repo.db
                .select(
                  'SELECT coalesce(sum(size),0) AS n FROM attachments WHERE data IS NOT NULL',
                )
                .first['n']
            as int),
  };

  Future<CloudLibraryInfo> libraryInfo() => api.library();

  Future<VerifiedBackup> createVerifiedBackup() async {
    final json = repo.db.transaction(() => exportAll(repo));
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
      final stored = repo.attachmentBytes(a.hash);
      if (sha256.convert(a.data).toString() != a.hash ||
          stored == null ||
          sha256.convert(stored).toString() != a.hash) {
        throw const CloudBackupException('Backup verification failed.');
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
    try {
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
      final read = parseExport(await file.readAsString());
      final expectedNotes = {
        for (final n in parsed.notes) n.id: recordDigest(n),
      };
      final expectedFolders = {
        for (final f in parsed.folders) f.id: recordDigest(f),
      };
      final actualNotes = {for (final n in read.notes) n.id: recordDigest(n)};
      final actualFolders = {
        for (final f in read.folders) f.id: recordDigest(f),
      };
      final expectedAttachments = {
        for (final a in parsed.attachments)
          a.hash: sha256.convert(a.data).toString(),
      };
      final actualAttachments = {
        for (final a in read.attachments)
          a.hash: sha256.convert(a.data).toString(),
      };
      if (!_sameMap(expectedNotes, actualNotes) ||
          !_sameMap(expectedFolders, actualFolders) ||
          !_sameMap(expectedAttachments, actualAttachments)) {
        await file.delete();
        throw const CloudBackupException(
          'Backup verification failed after writing.',
        );
      }
      // Directory fsync is not available through dart:io on every platform.
    } on Object {
      if (await tmp.exists()) await tmp.delete();
      if (await file.exists()) await file.delete();
      rethrow;
    }
    return VerifiedBackup(
      file.path,
      parsed.notes.length,
      parsed.folders.length,
      parsed.attachments.length,
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
    final dbHashes = repo.db
        .select('SELECT hash FROM attachments WHERE data IS NOT NULL')
        .map((row) => row['hash'] as String)
        .toSet();
    if (!verified.attachments.every(
      (attachment) =>
          dbHashes.contains(attachment.hash) &&
          sha256.convert(attachment.data).toString() == attachment.hash,
    )) {
      throw const CloudBackupException(
        'The verified backup attachments changed.',
      );
    }
    final resumingUpload = repo.db.getMeta('cloud.phase') == 'uploading';
    _uploading = true;
    repo.db.transaction(() => repo.db.setMeta('cloud.phase', 'uploading'));
    if (!resumingUpload) {
      repo.db.transaction(() => repo.db.setMeta('cloud.upload_progress', '0'));
      engine.progress = CloudSyncProgress(total: _pendingCount);
    }
    notifyListeners();
    try {
      String id;
      final session = await sessions.read();
      if (session == null) {
        throw const CloudApiException(
          CloudErrorKind.unauthorized,
          'You are signed out of cloud sync.',
        );
      }
      final linked = repo.db.getMeta('cloud.library_id');
      if (linked != null) {
        final existing = await api.library();
        if (existing.uploaderDeviceId != session.deviceId) {
          throw StateError('This device cannot resume the library upload.');
        }
        id = existing.libraryId;
        if (existing.state == 'ready') {
          _lastSync = DateTime.now();
          _lastError = null;
          repo.db.transaction(() {
            repo.db.setMeta('cloud.phase', 'ready');
            repo.db.setMeta(
              'cloud.last_sync_at',
              '${_lastSync!.millisecondsSinceEpoch}',
            );
          });
          return;
        }
        if (existing.state != 'uploading') {
          throw StateError('The cloud library is not ready for upload.');
        }
      } else {
        final init = await api.initLibrary();
        if (init['deviceId'] != session.deviceId) {
          throw const CloudApiException(
            CloudErrorKind.unauthorized,
            'Cloud did not recognize this signed-in device.',
          );
        }
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
      final uploadSnapshotSeq = repo.db.currentSeq;
      var done = resumingUpload
          ? int.tryParse(repo.db.getMeta('cloud.upload_progress') ?? '') ?? 0
          : 0;
      for (final kind in ['folder', 'note']) {
        var afterSeq = 0;
        while (true) {
          final page = repo.cloudRecordsSince(afterSeq, limit: 300);
          if (page.isEmpty) break;
          afterSeq = page.last.seq;
          final rows = page
              .where((r) => r.seq <= uploadSnapshotSeq && r.kind == kind)
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
            if (results.length != push.length ||
                push.any(
                  (item) => !results.any(
                    (result) =>
                        result.kind == item.kind && result.id == item.id,
                  ),
                )) {
              throw const CloudApiException(
                CloudErrorKind.malformed,
                'Cloud returned incomplete upload results.',
              );
            }
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
            repo.db.transaction(
              () => repo.db.setMeta('cloud.upload_progress', '$done'),
            );
            onProgress?.call(engine.progress);
            notifyListeners();
          }
          if (page.length < 300) break;
        }
      }
      repo.db.transaction(
        () => repo.db.setMeta('cloud.push_seq', '$uploadSnapshotSeq'),
      );
      await api.markReady(id);
      _lastSync = DateTime.now();
      _lastError = null;
      repo.db.transaction(() {
        repo.db.setMeta('cloud.phase', 'ready');
        repo.db.setMeta(
          'cloud.last_sync_at',
          '${_lastSync!.millisecondsSinceEpoch}',
        );
      });
    } catch (e) {
      _lastError = 'Upload could not finish.';
      rethrow;
    } finally {
      _uploading = false;
      notifyListeners();
    }
  }

  Future<JoinReport> inspectForJoin() async {
    final library = await api.library();
    final totalRecords = library.notes + library.folders;
    final remote = <String, String>{};
    String? after;
    while (true) {
      final page = await api.manifest(after: after);
      if (page.length > 500 || remote.length + page.length > 100000) {
        throw const CloudApiException(
          CloudErrorKind.malformed,
          'Cloud manifest is too large.',
        );
      }
      var previous = after ?? '';
      for (final x in page) {
        final key = '${x.kind}:${x.id}';
        if ((x.kind != 'note' && x.kind != 'folder') ||
            !_validManifestId(x.id) ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(x.digest) ||
            key.compareTo(previous) <= 0) {
          throw const CloudApiException(
            CloudErrorKind.malformed,
            'Cloud manifest is invalid.',
          );
        }
        remote[key] = x.digest;
        previous = key;
      }
      _joinProgress = CloudSyncProgress(
        uploaded: remote.length,
        total: totalRecords,
      );
      repo.db.transaction(
        () => repo.db.setMeta('cloud.join_progress', '${remote.length}'),
      );
      notifyListeners();
      if (page.length < 500) {
        break;
      }
      after = '${page.last.kind}:${page.last.id}';
    }
    final local = <String, String>{};
    var localCursor = -1;
    while (true) {
      final page = repo.cloudRecordsSince(localCursor, limit: 300);
      if (page.isEmpty) break;
      for (final r in page) {
        final id = switch (r.record) {
          NoteRecord note => note.id,
          FolderRecord folder => folder.id,
          _ => throw StateError('Unexpected local cloud record.'),
        };
        local['${r.kind}:$id'] = recordDigest(r.record);
      }
      localCursor = page.last.seq;
      if (page.length < 300) break;
    }
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

  bool _validManifestId(String value) => RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value);

  Future<void> join(JoinReport report) async {
    // Re-run the dry run at the point of action so stale UI state cannot
    // authorize a join after either local or remote rows changed.
    report = await inspectForJoin();
    final isEmpty = repo.cloudRecordsSince(-1, limit: 1).isEmpty;
    if (!report.exact && !isEmpty) {
      throw StateError('The libraries do not match exactly.');
    }
    final library = await api.library();
    final id = library.libraryId;
    final head = await api.head();
    if (head['libraryId'] != id) {
      throw const CloudApiException(
        CloudErrorKind.libraryMismatch,
        'Cloud library changed.',
      );
    }
    // Link only after both endpoints agree on the same library.
    repo.db.transaction(() => repo.db.setMeta('cloud.library_id', id));
    repo.db.transaction(() => repo.db.setMeta('cloud.phase', 'signedIn'));
    if (_enabled) {
      await start();
      await syncNow();
    } else {
      engine.resume();
      await engine.sync();
      _lastSync = DateTime.now();
    }
  }

  Future<void> syncNow() async {
    _retry?.cancel();
    _failures = 0;
    await _runSync();
  }

  /// Loads secure credentials before LAN auto-sync can be scheduled at app
  /// startup. Also refreshes the in-memory persisted state after a restart.
  Future<void> restoreState() async {
    if (unavailable) return;
    _signedIn = await sessions.read() != null;
    if (!_signedIn && _enabled) {
      repo.db.transaction(() => repo.db.setMeta('cloud.phase', 'signedOut'));
    }
    notifyListeners();
  }

  Future<void> _runSync() async {
    if (unavailable ||
        !_enabled ||
        !_running ||
        _syncing ||
        repo.db.getMeta('cloud.library_id') == null) {
      return;
    }
    _syncing = true;
    notifyListeners();
    try {
      final session = await sessions.read();
      if (session == null) {
        _signedIn = false;
        _lastError = 'You are signed out of cloud sync.';
        repo.db.transaction(() => repo.db.setMeta('cloud.phase', 'signedOut'));
        return;
      }
      _signedIn = true;
      await engine.sync();
      _lastSync = DateTime.now();
      _lastNeonBackstop = _lastSync;
      repo.db.transaction(() {
        repo.db.setMeta('cloud.phase', 'ready');
        repo.db.setMeta(
          'cloud.last_sync_at',
          '${_lastSync!.millisecondsSinceEpoch}',
        );
      });
      if (engine.unavailableBlobs.isNotEmpty) {
        _lastError = 'Some attachments could not sync and will be retried.';
        _needsAttention = true;
      } else {
        _lastError = null;
        _needsAttention = false;
      }
    } on CloudApiException catch (e) {
      if (e.kind == CloudErrorKind.unauthorized) {
        await sessions.write(null);
        _signedIn = false;
        _enabled = false;
        await stop();
        repo.db.transaction(() {
          repo.db.setMeta('cloud.enabled', 'off');
          repo.db.setMeta('cloud.phase', 'signedOut');
        });
        _lastError = 'You are signed out of cloud sync. Sign in again.';
        _needsAttention = true;
      } else if (e.kind == CloudErrorKind.libraryMismatch) {
        _lastError =
            'The linked cloud library has changed. Re-link before syncing.';
        _needsAttention = true;
        await stop();
      } else {
        _lastError = e.message;
        _needsAttention = true;
        _scheduleRetry(e.retryAfter);
      }
    } on Object {
      _lastError = 'Cloud sync could not complete.';
      _needsAttention = true;
      _scheduleRetry();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> start() async {
    if (unavailable || _running) return;
    await restoreState();
    if (_signedIn && repo.db.getMeta('cloud.phase') == 'uploading') {
      unawaited(_resumeUpload());
      return;
    }
    if (!_signedIn ||
        !_enabled ||
        repo.db.getMeta('cloud.library_id') == null) {
      notifyListeners();
      return;
    }
    engine.resume();
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
      if (h['libraryId'] != repo.db.getMeta('cloud.library_id')) {
        _lastError = 'The linked cloud library has changed.';
        _needsAttention = true;
        await stop();
        notifyListeners();
        return;
      }
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
    engine.cancel();
    _poll?.cancel();
    _debounce?.cancel();
    _retry?.cancel();
    repo.changes.removeListener(_localChanged);
  }

  void _scheduleRetry([Duration? serverDelay]) {
    if (!_running) return;
    const backoff = [
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 10),
      Duration(minutes: 30),
    ];
    final wait = serverDelay ?? backoff[_failures.clamp(0, backoff.length - 1)];
    _failures++;
    _retry?.cancel();
    _retry = Timer(wait, () => unawaited(_runSync()));
  }

  Future<void> _resumeUpload() async {
    try {
      final session = await sessions.read();
      if (session == null) return;
      CloudLibraryInfo library;
      try {
        library = await api.library();
      } on CloudApiException catch (e) {
        if (e.kind != CloudErrorKind.notFound) rethrow;
        try {
          final created = await api.initLibrary();
          repo.db.transaction(
            () => repo.db.setMeta(
              'cloud.library_id',
              created['libraryId'] as String,
            ),
          );
          library = await api.library();
        } on CloudApiException catch (initError) {
          if (initError.kind != CloudErrorKind.conflict) rethrow;
          library = await api.library();
        }
      }
      if (library.uploaderDeviceId != session.deviceId) {
        throw StateError('This device cannot resume the library upload.');
      }
      repo.db.transaction(
        () => repo.db.setMeta('cloud.library_id', library.libraryId),
      );
      if (library.state == 'ready') {
        repo.db.transaction(() => repo.db.setMeta('cloud.phase', 'ready'));
        return;
      }
      await uploadLibrary(await createVerifiedBackup());
    } on Object {
      _lastError = 'The interrupted upload could not resume.';
      _needsAttention = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(stop());
    loginLauncher?.cancel();
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
