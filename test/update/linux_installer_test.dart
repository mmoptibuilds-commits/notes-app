import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/app_version.dart';
import 'package:notes/update/github_release_client.dart';
import 'package:notes/update/installer.dart';
import 'package:notes/update/linux_installer.dart';
import 'package:notes/update/manifest.dart';

import 'fixtures.dart';

class FakeLauncher implements UpdateProcessLauncher {
  final runs = <List<String>>[];
  final started = <({String exe, List<String> args})>[];
  int chmodResult = 0;
  Object? startError;

  @override
  Future<int> run(String executable, List<String> args) async {
    runs.add([executable, ...args]);
    return chmodResult;
  }

  @override
  Future<void> startDetached(String executable, List<String> args) async {
    if (startError != null) throw startError!;
    started.add((exe: executable, args: args));
  }
}

void main() {
  late Directory home;
  late Directory install;
  late FakeLauncher launcher;
  late int quits;
  late List<String> order;

  setUp(() {
    home = Directory.systemTemp.createTempSync('notes_linux_installer');
    install = Directory('${home.path}/.local/opt/notes')
      ..createSync(recursive: true);
    Directory('${install.path}/bundle').createSync();
    Directory('${install.path}/update').createSync();
    File('${install.path}/bundle/notes').writeAsStringSync('binary');
    File('${install.path}/.managed-install').writeAsStringSync('1');
    File('${install.path}/update/notes-update-helper')
        .writeAsStringSync('#!/bin/sh\n');
    launcher = FakeLauncher();
    quits = 0;
    order = [];
  });
  tearDown(() => home.deleteSync(recursive: true));

  LinuxUpdateInstaller make({
    String? exe,
    Map<String, String>? env,
    String? installDir,
    UpdatePlatform? platform,
  }) => LinuxUpdateInstaller(
    onQuit: () async {
      quits++;
      order.add('quit:${launcher.started.length}');
    },
    launcher: launcher,
    environment: env ?? {'HOME': home.path},
    resolvedExecutable: exe ?? '${install.path}/bundle/notes',
    installDir: installDir,
    currentPid: 4242,
    tempRoot: Directory(home.path),
    freeSpaceProbe: (_) async => 1 << 30,
    platform: platform ?? const UpdatePlatform(UpdateOs.linux, 'x64'),
  );

  UpdateCandidate candidate({bool signed = true}) {
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
      assetUrl: Uri.parse('https://example.test/x.tar.gz'),
      signed: signed,
      platform: const UpdatePlatform(UpdateOs.linux, 'x64'),
    );
  }

  Future<ReadyUpdate> ready({bool signed = true}) async {
    final dir = Directory(
      '${home.path}/.local/state/com.mmoptibuilds.notes/updates',
    )..createSync(recursive: true);
    final f = File('${dir.path}/notes-1.0.1-linux-x64.tar.gz')
      ..writeAsBytesSync([1]);
    return ReadyUpdate(candidate(signed: signed), f);
  }

  group('prepare', () {
    test(
      'a managed install is ready, with state and updates outside the data dir',
      () async {
        final i = make();
        final info = await i.prepare();
        expect(info.block, isNull);
        expect(info.installedVersion, appVersionName);
        expect(info.installedBuild, appBuildNumber);
        expect(
          info.updateDir.path,
          '${home.path}/.local/state/com.mmoptibuilds.notes/updates',
        );
        expect(
          i.stateDir,
          '${home.path}/.local/state/com.mmoptibuilds.notes/updater',
        );
        expect(info.updateDir.path, isNot(contains('.local/share')));
      },
    );

    test('XDG_STATE_HOME is honoured', () async {
      final i = make(
        env: {'HOME': home.path, 'XDG_STATE_HOME': '${home.path}/xdg'},
      );
      expect(i.stateDir, '${home.path}/xdg/com.mmoptibuilds.notes/updater');
      expect(
        (await i.prepare()).updateDir.path,
        '${home.path}/xdg/com.mmoptibuilds.notes/updates',
      );
    });

    test(
      'running from somewhere else is blocked with manual guidance',
      () async {
        final info = await make(
          exe: '${home.path}/Downloads/notes/bundle/notes',
        ).prepare();
        expect(info.block!.kind, BlockKind.unmanagedInstall);
        expect(info.block!.message, contains('install.sh'));
      },
    );

    test(
      'a path that merely shares a prefix is not inside the install',
      () async {
        final sibling = Directory('${install.path}-other/bundle')
          ..createSync(recursive: true);
        File('${sibling.path}/notes').writeAsStringSync('x');
        final info = await make(exe: '${sibling.path}/notes').prepare();
        expect(info.block, isNotNull);
      },
    );

    test('a symlinked executable is resolved before the check', () async {
      final outside = Directory('${home.path}/elsewhere')..createSync();
      File('${outside.path}/notes').writeAsStringSync('x');
      Link('${install.path}/bundle/link').createSync('${outside.path}/notes');
      final info = await make(exe: '${install.path}/bundle/link').prepare();
      expect(info.block, isNotNull);
    });

    test('no marker file means unmanaged', () async {
      File('${install.path}/.managed-install').deleteSync();
      expect((await make().prepare()).block!.kind, BlockKind.unmanagedInstall);
    });

    test('no helper means blocked', () async {
      File('${install.path}/update/notes-update-helper').deleteSync();
      expect((await make().prepare()).block!.message, contains('helper'));
    });

    test('a missing install directory is blocked, not a crash', () async {
      final info = await make(installDir: '${home.path}/nowhere').prepare();
      expect(info.block, isNotNull);
    });

    test('another CPU is blocked', () async {
      final info = await make(
        platform: const UpdatePlatform(UpdateOs.linux, 'arm64'),
      ).prepare();
      expect(info.block!.kind, BlockKind.unsupportedArch);
    });
  });

  group('install', () {
    test('copies the helper, starts it detached with the contract arguments, then quits', () async {
      final i = make();
      final info = await i.prepare();
      final r = await i.install(await ready(), info);
      expect(r, isA<InstallHandedToOs>());
      expect((r as InstallHandedToOs).willRestart, isTrue);
      expect(quits, 1);

      final s = launcher.started.single;
      // Started through the shell (works on a noexec temp dir), on a private
      // copy rather than the file inside the install being replaced.
      expect(s.exe, '/bin/sh');
      final helperCopy = s.args.first;
      expect(helperCopy, isNot(startsWith(install.path)));
      expect(File(helperCopy).readAsStringSync(), '#!/bin/sh\n');
      expect(helperCopy, endsWith('/notes-update-helper'));
      expect(s.args.skip(1).toList(), [
        'apply',
        '--pid',
        '4242',
        '--archive',
        '${home.path}/.local/state/com.mmoptibuilds.notes/updates/notes-1.0.1-linux-x64.tar.gz',
        '--sha256',
        sha64a,
        '--size',
        '1000',
        '--install',
        install.path,
        '--state-dir',
        i.stateDir,
        '--version',
        '1.0.1',
        '--relaunch',
      ]);
      // chmod 700 on the private directory and on the copied helper.
      expect(
        launcher.runs.every((c) => c[0] == 'chmod' && c[1] == '700'),
        isTrue,
      );
      expect(launcher.runs.map((c) => c[2]), contains(helperCopy));
      expect(Directory(i.stateDir).existsSync(), isTrue);
    });

    test('the helper is started before the app quits', () async {
      final i = make();
      final info = await i.prepare();
      await i.install(await ready(), info);
      expect(order, ['quit:1']);
    });

    test('an unsigned manifest never installs on Linux', () async {
      final i = make();
      final info = await i.prepare();
      final r = await i.install(await ready(signed: false), info);
      expect((r as InstallFailed).message, contains('not provisioned'));
      expect(launcher.started, isEmpty);
      expect(quits, 0);
    });

    test('a blocked install never installs', () async {
      File('${install.path}/.managed-install').deleteSync();
      final i = make();
      final info = await i.prepare();
      expect(await i.install(await ready(), info), isA<InstallFailed>());
      expect(launcher.started, isEmpty);
      expect(quits, 0);
    });

    test('if the helper cannot be started, Notes does not quit', () async {
      launcher.startError = const ProcessException('x', []);
      final i = make();
      final info = await i.prepare();
      expect(await i.install(await ready(), info), isA<InstallFailed>());
      expect(quits, 0);
    });

    test('a failed chmod stops before anything starts', () async {
      launcher.chmodResult = 1;
      final i = make();
      final info = await i.prepare();
      expect(await i.install(await ready(), info), isA<InstallFailed>());
      expect(launcher.started, isEmpty);
      expect(quits, 0);
    });
  });

  group('next launch', () {
    Future<InstallOutcome?> outcome(Object? status) async {
      final i = make();
      final info = await i.prepare();
      Directory(i.stateDir).createSync(recursive: true);
      File('${i.stateDir}/update.json')
          .writeAsStringSync(status is String ? status : jsonEncode(status));
      return i.lastOutcome(info);
    }

    test(
      'a finished update to the running version says "Updated to"',
      () async {
        final o = await outcome({
          'phase': 'done',
          'fromVersion': '0.9.0',
          'toVersion': appVersionName,
          'ok': true,
          'error': null,
          'time': '2026-12-02T10:00:00Z',
        });
        expect(o!.updated, isTrue);
        expect(o.message, 'Updated to $appVersionName.');
        expect(o.id, 'linux:2026-12-02T10:00:00Z');
      },
    );

    test(
      'success recorded for a version that is not running is not claimed',
      () async {
        final o = await outcome({
          'phase': 'done',
          'toVersion': '9.9.9',
          'ok': true,
          'time': 't',
        });
        expect(o, isNull);
      },
    );

    test(
      'a failure shows the helper error and says data is untouched',
      () async {
        final o = await outcome({
          'phase': 'swap',
          'toVersion': '1.0.1',
          'ok': false,
          'error': 'checksum\nmismatch',
          'time': 't2',
        });
        expect(o!.updated, isFalse);
        expect(o.message, contains('did not finish: checksum mismatch'));
        expect(o.message, contains('not touched'));
      },
    );

    test('a long error is truncated', () async {
      final o = await outcome({
        'toVersion': '1.0.1',
        'ok': false,
        'error': 'x' * 1000,
        'time': 't',
      });
      expect(o!.message.length, lessThan(500));
    });

    test('missing, damaged or in-progress status reports nothing', () async {
      expect(await make().lastOutcome(await make().prepare()), isNull);
      expect(await outcome('{{'), isNull);
      expect(await outcome('[]'), isNull);
      expect(
        await outcome({'phase': 'extract', 'toVersion': '1.0.1', 'time': 't'}),
        isNull,
      );
    });
  });

  test('verifyDownloaded fails when the archive vanished', () async {
    final i = make();
    final info = await i.prepare();
    final r = await ready();
    r.file.deleteSync();
    await expectLater(
      i.verifyDownloaded(r, info),
      throwsA(isA<UpdateVerificationFailure>()),
    );
  });

  test('acceptsUnsignedManifest is false', () {
    expect(make().acceptsUnsignedManifest, isFalse);
  });
}
