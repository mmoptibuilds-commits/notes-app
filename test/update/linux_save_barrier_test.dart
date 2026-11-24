import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/widgets.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart' show Attribute;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:notes/core/version_vector.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/data/editor_save_barrier.dart';
import 'package:notes/data/models.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/peers.dart';
import 'package:notes/sync/sync_service.dart';
import 'package:notes/ui/editor/editor_session.dart';
import 'package:notes/update/github_release_client.dart';
import 'package:notes/update/installer.dart';
import 'package:notes/update/linux_installer.dart';
import 'package:notes/update/manifest.dart';

import 'fixtures.dart';

class _FakeLauncher implements UpdateProcessLauncher {
  final runs = <List<String>>[];
  final started = <({String executable, List<String> args})>[];
  Future<void> Function()? beforeStart;
  Future<void> Function(String executable, List<String> args)? beforeRun;
  Object? startError;

  @override
  Future<int> run(String executable, List<String> args) async {
    runs.add([executable, ...args]);
    await beforeRun?.call(executable, args);
    return 0;
  }

  @override
  Future<void> startDetached(String executable, List<String> args) async {
    await beforeStart?.call();
    if (startError != null) throw startError!;
    started.add((executable: executable, args: args));
  }
}

class _FailingRepository extends NoteRepository {
  _FailingRepository(super.db);

  bool failWrites = false;
  var attempts = 0;

  @override
  SaveResult saveContent(
    String id, {
    required String title,
    required String body,
    required VersionVector base,
  }) {
    attempts++;
    if (failWrites) throw StateError('synthetic storage failure');
    return super.saveContent(id, title: title, body: body, base: base);
  }
}

class _CountingSyncService extends SyncService {
  _CountingSyncService({
    required super.repo,
    required super.peers,
    required super.identity,
  }) : super(
         deviceName: 'Synthetic test device',
         port: 0,
         enableDiscovery: false,
         localAddresses: () async => const [],
       );

  var disposeCount = 0;
  Object? disposeError;

  @override
  void dispose() {
    disposeCount++;
    if (disposeError != null) throw disposeError!;
    super.dispose();
  }
}

class _Harness {
  _Harness._(this.db, this.repo, this.barrier, this.sync, this.services);

  final AppDatabase db;
  final _FailingRepository repo;
  final EditorSaveBarrier barrier;
  final _CountingSyncService sync;
  final AppServices services;
  var exitCalls = 0;
  var quitCalled = false;

  static Future<_Harness> create({
    Duration barrierTimeout = const Duration(seconds: 2),
  }) async {
    final db = AppDatabase.open(null);
    final repo = _FailingRepository(db);
    final barrier = EditorSaveBarrier(timeout: barrierTimeout);
    final identity = await DeviceIdentity.loadOrCreate(db);
    final sync = _CountingSyncService(
      repo: repo,
      peers: PeerStore(db),
      identity: identity,
    );
    late final _Harness harness;
    final services = AppServices(
      db,
      repo,
      AppSettings(db),
      '',
      sync: sync,
      saveBarrier: barrier,
      exitProcess: (_) {
        harness.exitCalls++;
        harness.quitCalled = true;
      },
    );
    harness = _Harness._(db, repo, barrier, sync, services);
    return harness;
  }

  void dispose() {
    if (quitCalled) {
      services.settings.dispose();
    } else {
      services.close();
    }
  }
}

String _body(String text) => jsonEncode((Delta()..insert(text)).toJson());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;
  late Directory install;
  late _FakeLauncher launcher;
  late _Harness? harness;

  setUp(() {
    home = Directory.systemTemp.createTempSync('notes_linux_save_barrier');
    install = Directory('${home.path}/.local/opt/notes')
      ..createSync(recursive: true);
    Directory('${install.path}/bundle').createSync();
    Directory('${install.path}/update').createSync();
    File('${install.path}/bundle/notes').writeAsStringSync('synthetic binary');
    File('${install.path}/.managed-install').writeAsStringSync('1');
    File('${install.path}/update/notes-update-helper')
        .writeAsStringSync('#!/bin/sh\n');
    launcher = _FakeLauncher();
    harness = null;
  });

  tearDown(() {
    harness?.dispose();
    home.deleteSync(recursive: true);
  });

  Future<_Harness> makeHarness({Duration? barrierTimeout}) async {
    final h = await _Harness.create(
      barrierTimeout: barrierTimeout ?? const Duration(seconds: 2),
    );
    harness = h;
    return h;
  }

  LinuxUpdateInstaller installer(
    _Harness h, {
    Future<void> Function()? onPrepareQuit,
    Future<void> Function()? onQuit,
  }) => LinuxUpdateInstaller(
    onPrepareQuit: onPrepareQuit ?? h.services.prepareForUpdate,
    onConfirmStillClean: h.barrier.confirmStillClean,
    onQuit: onQuit ?? h.services.quitForUpdate,
    onInstallAborted: () => h.services.abortUpdatePreparation(),
    launcher: launcher,
    environment: {'HOME': home.path},
    resolvedExecutable: '${install.path}/bundle/notes',
    currentPid: 4242,
    tempRoot: Directory(home.path),
    freeSpaceProbe: (_) async => 1 << 30,
    platform: const UpdatePlatform(UpdateOs.linux, 'x64'),
  );

  UpdateCandidate candidate() {
    const artifact = ManifestArtifact(
      platform: 'linux',
      arch: 'x64',
      filename: 'notes-1.0.1-linux-x64.tar.gz',
      sha256: sha64a,
      size: 1000,
    );
    return UpdateCandidate(
      release: const GithubRelease(
        tag: 'v1.0.1',
        version: '1.0.1',
        notes: '',
        assets: [],
      ),
      manifest: UpdateManifest(
        version: '1.0.1',
        buildNumber: 20261123,
        publishedAt: DateTime.utc(2026, 12, 1),
        expires: DateTime.utc(2027, 6, 1),
        artifacts: const [artifact],
      ),
      artifact: artifact,
      assetUrl: Uri.parse('https://example.test/notes.tar.gz'),
      signed: true,
      platform: const UpdatePlatform(UpdateOs.linux, 'x64'),
    );
  }

  Future<ReadyUpdate> ready() async {
    final dir = Directory(
      '${home.path}/.local/state/com.mmoptibuilds.notes/updates',
    )..createSync(recursive: true);
    final file = File('${dir.path}/notes-1.0.1-linux-x64.tar.gz')
      ..writeAsBytesSync([1]);
    return ReadyUpdate(candidate(), file);
  }

  EditorSession openSession(_Harness h, String id) => EditorSession(
    repo: h.repo,
    saveBarrier: h.barrier,
    noteId: id,
    useCompletedSection: false,
    autosaveDelay: const Duration(hours: 1),
  );

  test(
    'pending edits flush before helper setup and stay frozen through quit',
    () async {
      final h = await makeHarness();
      final note = h.repo.createNote(
        title: 'Before',
        body: _body('old text\n'),
      );
      final session = openSession(h, note.id);
      session.quill.replaceText(
        0,
        0,
        'pending ',
        const TextSelection.collapsed(offset: 8),
      );
      session.title.text = 'Saved title';

      launcher.beforeStart = () async {
        expect(session.readOnly, isTrue);
        expect(h.repo.getNote(note.id)!.title, 'Saved title');
        expect(h.repo.getNote(note.id)!.preview, 'pending old text');
      };
      final i = installer(h);
      final info = await i.prepare();
      final result = await i.install(await ready(), info);

      expect(result, isA<InstallHandedToOs>());
      expect(launcher.started, hasLength(1));
      expect(h.exitCalls, 1);
      expect(h.sync.disposeCount, 1);
      expect(session.readOnly, isTrue);
      session.dispose();
    },
  );

  test('a frozen checklist compose is included in the barrier save', () async {
    final h = await makeHarness();
    final note = h.repo.createNote(body: _body('task\n'));
    final session = EditorSession(
      repo: h.repo,
      saveBarrier: h.barrier,
      noteId: note.id,
      autosaveDelay: const Duration(hours: 1),
    );
    var composed = false;
    session.addListener(() {
      if (!session.frozenForUpdate || composed) return;
      composed = true;
      session.quill.formatText(4, 0, Attribute.checked);
    });

    await h.barrier.prepare();

    expect(composed, isTrue);
    expect(
      jsonDecode(h.repo.getNote(note.id)!.body),
      (Delta()
            ..insert('task')
            ..insert('\n', {'list': 'checked'}))
          .toJson(),
    );

    h.barrier.release();
    await pumpEventQueue();
    expect(session.completed.map((line) => line.text), ['task']);
    expect(session.quill.document.toPlainText(), '\n');
    session.dispose();
  });

  test(
    'compose after prepare aborts before launch and Retry saves it',
    () async {
      final h = await makeHarness();
      final note = h.repo.createNote(body: _body('old text\n'));
      final session = openSession(h, note.id);
      final i = installer(h);
      final info = await i.prepare();
      final update = await ready();
      var edited = false;
      launcher.beforeRun = (_, _) async {
        if (edited) return;
        edited = true;
        session.quill.replaceText(
          0,
          0,
          'late ',
          const TextSelection.collapsed(offset: 5),
        );
      };

      final failed = await i.install(update, info);

      expect(failed, isA<InstallFailed>());
      expect((failed as InstallFailed).retry, isTrue);
      expect(launcher.started, isEmpty);
      expect(session.readOnly, isFalse);
      expect(h.repo.getNote(note.id)!.preview, 'old text');
      expect(h.db.select('SELECT count(*) AS n FROM notes').single['n'], 1);
      expect(h.sync.disposeCount, 0);
      expect(h.exitCalls, 0);

      launcher.beforeRun = null;
      launcher.beforeStart = () async {
        expect(h.repo.getNote(note.id)!.preview, 'late old text');
      };
      final retried = await i.install(update, info);
      expect(retried, isA<InstallHandedToOs>());
      expect(launcher.started, hasLength(1));
      expect(h.sync.disposeCount, 1);
      expect(h.exitCalls, 1);
      session.dispose();
    },
  );

  test(
    'quit exits and closes the database when sync disposal throws',
    () async {
      final h = await makeHarness();
      h.sync.disposeError = StateError('synthetic sync disposal failure');

      await h.services.quitForUpdate();

      expect(h.sync.disposeCount, 1);
      expect(h.exitCalls, 1);
      expect(() => h.db.select('SELECT 1'), throwsA(anything));
    },
  );

  test(
    'save failure leaves services open and Retry re-runs the barrier',
    () async {
      final h = await makeHarness();
      final note = h.repo.createNote(body: _body('old text\n'));
      final session = openSession(h, note.id);
      session.quill.replaceText(
        0,
        0,
        'pending ',
        const TextSelection.collapsed(offset: 8),
      );
      h.repo.failWrites = true;
      var barriers = 0;
      final i = installer(
        h,
        onPrepareQuit: () async {
          barriers++;
          await h.services.prepareForUpdate();
        },
      );
      final info = await i.prepare();
      final update = await ready();

      final failed = await i.install(update, info) as InstallFailed;
      expect(failed.retry, isTrue);
      expect(failed.message, contains('Notes is still open'));
      expect(launcher.started, isEmpty);
      expect(launcher.runs, isEmpty);
      expect(
        home.listSync().whereType<Directory>().where(
          (dir) => p.basename(dir.path).startsWith('notes-update-'),
        ),
        isEmpty,
      );
      expect(Directory(i.stateDir).existsSync(), isFalse);
      expect(session.readOnly, isFalse);
      expect(session.quill.document.toPlainText(), 'pending old text\n');
      expect(h.repo.getNote(note.id)!.preview, 'old text');
      expect(h.db.select('SELECT count(*) AS n FROM notes').single['n'], 1);
      expect(h.sync.disposeCount, 0);
      expect(h.exitCalls, 0);

      h.repo.failWrites = false;
      launcher.beforeStart = () async {
        expect(h.repo.getNote(note.id)!.preview, 'pending old text');
        expect(session.readOnly, isTrue);
      };
      final retried = await i.install(update, info);
      expect(retried, isA<InstallHandedToOs>());
      expect(barriers, 2);
      expect(launcher.started, hasLength(1));
      expect(h.exitCalls, 1);
      expect(h.sync.disposeCount, 1);
      expect(session.readOnly, isTrue);
      session.dispose();
    },
  );

  test('barrier sees a failed save handed off after editor disposal', () async {
    final h = await makeHarness();
    final note = h.repo.createNote(body: _body('old text\n'));
    final session = openSession(h, note.id);
    session.quill.replaceText(
      0,
      0,
      'handed off ',
      const TextSelection.collapsed(offset: 12),
    );
    h.repo.failWrites = true;
    session.flush();
    session.dispose();
    h.repo.failWrites = false;

    var barriers = 0;
    final i = installer(
      h,
      onPrepareQuit: () async {
        barriers++;
        await h.services.prepareForUpdate();
      },
      onQuit: () async {},
    );
    launcher.beforeStart = () async {
      expect(h.repo.getNote(note.id)!.preview, 'handed off old text');
    };
    final info = await i.prepare();
    final result = await i.install(await ready(), info);

    expect(result, isA<InstallHandedToOs>());
    expect(barriers, 1);
    expect(launcher.started, hasLength(1));
    expect(h.repo.getNote(note.id)!.preview, 'handed off old text');
    expect(h.repo.attempts, greaterThanOrEqualTo(3));
  });

  test('an unconfirmed save times out without arming the helper', () async {
    final h = await makeHarness(
      barrierTimeout: const Duration(milliseconds: 20),
    );
    final note = h.repo.createNote(body: _body('old text\n'));
    final gate = Completer<void>();
    final session = _GatedEditorSession(
      repo: h.repo,
      saveBarrier: h.barrier,
      noteId: note.id,
      useCompletedSection: false,
      autosaveDelay: const Duration(hours: 1),
      gate: gate,
    );
    session.quill.replaceText(
      0,
      0,
      'pending ',
      const TextSelection.collapsed(offset: 8),
    );
    final i = installer(h);
    final info = await i.prepare();

    final failed = await i.install(await ready(), info) as InstallFailed;
    expect(failed.retry, isTrue);
    expect(session.readOnly, isFalse);
    expect(session.quill.document.toPlainText(), 'pending old text\n');
    expect(launcher.started, isEmpty);
    expect(launcher.runs, isEmpty);
    expect(Directory(i.stateDir).existsSync(), isFalse);
    expect(h.db.select('SELECT count(*) AS n FROM notes').single['n'], 1);
    expect(h.sync.disposeCount, 0);
    expect(h.exitCalls, 0);

    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(h.repo.getNote(note.id)!.preview, 'pending old text');
    session.dispose();
  });

  test('helper launch failure releases the editor freeze', () async {
    final h = await makeHarness();
    final note = h.repo.createNote(body: _body('old text\n'));
    final session = openSession(h, note.id);
    session.quill.replaceText(
      0,
      0,
      'pending ',
      const TextSelection.collapsed(offset: 8),
    );
    launcher.startError = const ProcessException(
      'synthetic launcher failure',
      [],
    );
    final i = installer(h);
    final info = await i.prepare();

    final failed = await i.install(await ready(), info) as InstallFailed;

    expect(failed.retry, isFalse);
    expect(launcher.started, isEmpty);
    expect(session.readOnly, isFalse);
    expect(h.repo.getNote(note.id)!.preview, 'pending old text');
    expect(h.sync.disposeCount, 0);
    expect(h.exitCalls, 0);
    expect(
      home.listSync().whereType<Directory>().where(
        (dir) => p.basename(dir.path).startsWith('notes-update-'),
      ),
      isEmpty,
    );
    session.dispose();
  });

  test('barrier waits for an in-flight save, freezes edits and single-flights install', () async {
    final h = await makeHarness();
    final note = h.repo.createNote(title: 'Before', body: _body('old\n'));
    final gate = Completer<void>();
    final session = _GatedEditorSession(
      repo: h.repo,
      saveBarrier: h.barrier,
      noteId: note.id,
      useCompletedSection: false,
      autosaveDelay: const Duration(hours: 1),
      gate: gate,
    );
    session.quill.replaceText(
      0,
      0,
      'pending ',
      const TextSelection.collapsed(offset: 8),
    );
    var barriers = 0;
    var quitCalls = 0;
    final i = installer(
      h,
      onPrepareQuit: () {
        barriers++;
        return h.services.prepareForUpdate();
      },
      onQuit: () async => quitCalls++,
    );
    final info = await i.prepare();
    final update = await ready();
    final first = i.install(update, info);
    await Future<void>.delayed(Duration.zero);

    expect(session.readOnly, isTrue);
    expect(session.flushCalls, 1);
    session.title.text = 'Too late';
    expect(session.title.text, 'Before');
    final second = i.install(update, info);
    expect(identical(first, second), isTrue);
    expect(barriers, 1);
    expect(launcher.started, isEmpty);

    gate.complete();
    final results = await Future.wait([first, second]);
    expect(results.every((result) => result is InstallHandedToOs), isTrue);
    expect(launcher.started, hasLength(1));
    expect(quitCalls, 1);
    expect(h.repo.getNote(note.id)!.preview, 'pending old');
    session.dispose();
  });
}

class _GatedEditorSession extends EditorSession {
  _GatedEditorSession({
    required this.gate,
    required super.repo,
    super.saveBarrier,
    super.noteId,
    super.useCompletedSection,
    super.autosaveDelay,
  });

  final Completer<void> gate;
  var flushCalls = 0;

  @override
  Future<void> flushForUpdate() async {
    flushCalls++;
    await gate.future;
    await super.flushForUpdate();
  }
}
