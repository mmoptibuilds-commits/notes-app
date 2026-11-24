import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/sync/cloud/record_digest.dart';

import '../../support/fake_cloud_server.dart';

void main() {
  test('polling pulls only on head advance and local edits debounce', () async {
    final db = AppDatabase.open(null);
    addTearDown(db.close);
    final repo = NoteRepository(db), server = FakeCloudServer();
    db.transaction(() {
      db.setMeta('cloud.library_id', server.libraryId);
      db.setMeta('cloud.enabled', 'on');
    });
    final sessions = MemoryCloudSessionStore()
      ..session = const CloudSession(
        deviceId: 'test-device',
        access: 'a',
        accessExp: 1,
        refresh: 'r',
      );
    final timers = <_ManualTimer>[];
    var now = DateTime.utc(2026, 1, 1);
    final service = CloudService(
      repo: repo,
      api: server,
      sessions: sessions,
      dataDir: '',
      deviceName: 'Synthetic',
      loginLauncher: null,
      unavailable: false,
      clock: () => now,
      timerFactory: (duration, callback) {
        final timer = _ManualTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
      periodicTimerFactory: (duration, callback) {
        final timer = _ManualTimer(duration, callback, periodic: true);
        timers.add(timer);
        return timer;
      },
      platformIsAndroid: () => false,
    );
    addTearDown(service.dispose);

    await service.start();
    final startingChanges = server.changesCalls;
    final poll = timers.singleWhere(
      (t) => t.duration == const Duration(seconds: 30),
    );
    poll.fire();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(server.headCalls, 1);
    expect(server.changesCalls, startingChanges);
    final sourceDb = AppDatabase.open(null);
    addTearDown(sourceDb.close);
    final source = NoteRepository(sourceDb);
    final remote = source.createNote(
      id: '00000000-0000-4000-8000-000000000090',
      title: 'remote',
    );
    final remoteRow = source.getRecord(remote.id)!.toJson();
    server.seq = 1;
    server.records['note:${remote.id}'] = CloudRecord(
      kind: 'note',
      id: remote.id,
      rev: 1,
      seq: 1,
      digest: recordDigest(remoteRow),
      row: remoteRow,
    );
    poll.fire();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(repo.getNote(remote.id)?.title, 'remote');
    final afterAdvance = server.changesCalls;
    now = now.add(const Duration(hours: 1));
    poll.fire();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(server.changesCalls, afterAdvance + 1);
    await service.lifecycleChanged(resumed: false, paused: true);
    repo.createNote(title: 'edited');
    final debounce = timers.last;
    expect(debounce.duration, const Duration(seconds: 20));
    final headCalls = server.headCalls;
    server.responseDelay = const Duration(milliseconds: 10);
    debounce.fire();
    poll.fire();
    expect(server.headCalls, headCalls);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.records, hasLength(2));
  });

  test(
    'retry delays progress through the backoff ladder and reset on success',
    () async {
      final db = AppDatabase.open(null);
      addTearDown(db.close);
      final repo = NoteRepository(db), server = FakeCloudServer();
      db.transaction(() {
        db.setMeta('cloud.library_id', server.libraryId);
        db.setMeta('cloud.enabled', 'on');
      });
      final sessions = MemoryCloudSessionStore()
        ..session = const CloudSession(
          deviceId: 'test-device',
          access: 'a',
          accessExp: 1,
          refresh: 'r',
        );
      final timers = <_ManualTimer>[];
      final service = CloudService(
        repo: repo,
        api: server,
        sessions: sessions,
        dataDir: '',
        deviceName: 'Synthetic',
        loginLauncher: null,
        unavailable: false,
        timerFactory: (duration, callback) {
          final timer = _ManualTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
        periodicTimerFactory: (duration, callback) {
          final timer = _ManualTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(service.dispose);
      await service.start();
      server.failStatusAtRequest = server.requestCount + 1;
      repo.createNote(title: 'synthetic');
      timers.lastWhere((t) => t.duration == const Duration(seconds: 20)).fire();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      var retry = timers.last;
      expect(retry.duration, const Duration(seconds: 30));
      for (final seconds in [120, 600, 1800]) {
        server.failStatusAtRequest = server.requestCount + 1;
        retry.fire();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        retry = timers.last;
        expect(retry.duration, Duration(seconds: seconds));
      }
      server.failStatusAtRequest = null;
      retry.fire();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      server.failStatusAtRequest = server.requestCount + 1;
      repo.createNote(title: 'after recovery');
      timers.lastWhere((t) => t.duration == const Duration(seconds: 20)).fire();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(timers.last.duration, const Duration(seconds: 30));
    },
  );

  test('Android pause stops polling and resume starts sync again', () async {
    final db = AppDatabase.open(null);
    addTearDown(db.close);
    final repo = NoteRepository(db), server = FakeCloudServer();
    db.transaction(() {
      db.setMeta('cloud.library_id', server.libraryId);
      db.setMeta('cloud.enabled', 'on');
    });
    final sessions = MemoryCloudSessionStore()
      ..session = const CloudSession(
        deviceId: 'test-device',
        access: 'a',
        accessExp: 1,
        refresh: 'r',
      );
    final timers = <_ManualTimer>[];
    final service = CloudService(
      repo: repo,
      api: server,
      sessions: sessions,
      dataDir: '',
      deviceName: 'Synthetic',
      loginLauncher: null,
      unavailable: false,
      timerFactory: (duration, callback) {
        final timer = _ManualTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
      periodicTimerFactory: (duration, callback) {
        final timer = _ManualTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
      platformIsAndroid: () => true,
    );
    addTearDown(service.dispose);
    await service.start();
    final poll = timers.singleWhere(
      (t) => t.duration == const Duration(seconds: 30),
    );
    await service.lifecycleChanged(resumed: false, paused: true);
    expect(poll.isActive, isFalse);
    final timerCount = timers.length;
    repo.createNote(title: 'while paused');
    expect(timers.length, timerCount);
    await service.lifecycleChanged(resumed: true, paused: false);
    expect(server.records, hasLength(1));
    await service.stop();
    expect(timers.every((timer) => !timer.isActive), isTrue);
  });

  test(
    'upload uses its verified rows and starts ongoing sync for later edits',
    () async {
      final db = AppDatabase.open(null);
      addTearDown(db.close);
      final repo = NoteRepository(db);
      final note = repo.createNote(
        id: '00000000-0000-4000-8000-000000000091',
        title: 'snapshot',
      );
      final server = FakeCloudServer()
        ..state = 'uploading'
        ..uploaderDeviceId = 'test-device';
      db.transaction(() {
        db.setMeta('cloud.library_id', server.libraryId);
        db.setMeta('cloud.phase', 'uploading');
      });
      final sessions = MemoryCloudSessionStore()
        ..session = CloudSession(
          deviceId: 'test-device',
          access: 'access',
          accessExp: 9999999999,
          refresh: 'r1.${'A' * 43}.${'B' * 43}',
        );
      final directory = await Directory.systemTemp.createTemp(
        'notes-cloud-service-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = CloudService(
        repo: repo,
        api: server,
        sessions: sessions,
        dataDir: directory.path,
        deviceName: 'Synthetic',
        loginLauncher: null,
        unavailable: false,
      );
      addTearDown(service.dispose);
      final snapshotBackup = await service.createVerifiedBackup();
      server.beforeMarkReady = () async {
        expect(server.records['note:${note.id}']?.row['title'], 'snapshot');
        final current = repo.getRecord(note.id)!;
        repo.saveContent(
          note.id,
          title: 'later edit',
          body: jsonEncode([
            {'insert': 'changed\n'},
          ]),
          base: current.contentVv,
        );
      };

      await service.uploadLibrary(snapshotBackup);

      expect(server.state, 'ready');
      expect(server.records['note:${note.id}']?.row['title'], 'later edit');
      expect(service.status.pendingRows, 0);
      expect(service.status.phase, CloudPhase.ready);
    },
  );
}

class _ManualTimer implements Timer {
  _ManualTimer(this.duration, this.callback, {this.periodic = false});
  final Duration duration;
  final void Function() callback;
  final bool periodic;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) return;
    if (!periodic) _active = false;
    callback();
  }
}
