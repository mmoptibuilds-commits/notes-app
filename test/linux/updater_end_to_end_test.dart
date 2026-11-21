import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/update/github_release_client.dart';
import 'package:notes/update/installer.dart';
import 'package:notes/update/linux_installer.dart';
import 'package:notes/update/manifest.dart';

class _EnvironmentLauncher implements UpdateProcessLauncher {
  _EnvironmentLauncher(this.environment);

  final Map<String, String> environment;

  @override
  Future<int> run(String executable, List<String> args) async =>
      (await Process.run(executable, args)).exitCode;

  @override
  Future<void> startDetached(String executable, List<String> args) async {
    await Process.start(
      executable,
      args,
      mode: ProcessStartMode.detached,
      environment: {...Platform.environment, ...environment},
    );
  }
}

/// The real Dart installer driving the real helper script, in a throwaway
/// HOME with a synthetic package: the contract between the two halves.
void main() {
  late Directory temp;
  late Directory home;
  late Directory install;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('notes-e2e-update-');
    home = Directory('${temp.path}/home')..createSync();
    install = Directory('${home.path}/.local/opt/notes')
      ..createSync(recursive: true);
    Directory('${install.path}/lib').createSync();
    Directory('${install.path}/data').createSync();
    Directory('${install.path}/update').createSync();
    File('tool/linux/notes-update-helper')
        .copySync('${install.path}/update/notes-update-helper');
    File('${install.path}/notes').writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('chmod', ['+x', '${install.path}/notes']);
    File('${install.path}/.managed-install').writeAsStringSync(
      '{"schema":1,"version":"1.0.0","installedAt":"2026-01-01T00:00:00Z"}\n',
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  String stateBase() => '${home.path}/.local/state/com.mmoptibuilds.notes';

  String quote(String value) => "'$value'";

  String startupScript(String lockPath, String markPath, String label) =>
      '#!/bin/sh\n'
      'if flock -w 3 ${quote(lockPath)} /bin/true; then\n'
      '  printf \'%s\\n\' ${quote(label)} > ${quote(markPath)}\n'
      'else\n'
      '  exit 44\n'
      'fi\n';

  Future<File> makeArchive(String newProgram) async {
    final root = Directory('${temp.path}/notes-1.0.1-linux-x64')..createSync();
    Directory('${root.path}/bundle/lib').createSync(recursive: true);
    Directory('${root.path}/bundle/data').createSync(recursive: true);
    Directory('${root.path}/update').createSync();
    File('tool/linux/notes-update-helper')
        .copySync('${root.path}/update/notes-update-helper');
    File('${root.path}/bundle/notes').writeAsStringSync(newProgram);
    Process.runSync('chmod', ['+x', '${root.path}/bundle/notes']);
    final archive = File('${temp.path}/notes-1.0.1-linux-x64.tar.gz');
    final tar = Process.runSync('tar', [
      '-czf',
      archive.path,
      '-C',
      temp.path,
      'notes-1.0.1-linux-x64',
    ]);
    expect(tar.exitCode, 0);
    return archive;
  }

  Future<ReadyUpdate> readyUpdate(File archive) async {
    final updates = Directory('${stateBase()}/updates')
      ..createSync(recursive: true);
    final stagedArchive = File(
      '${updates.path}/${archive.uri.pathSegments.last}',
    )..writeAsBytesSync(archive.readAsBytesSync());
    final sha =
        (Process.runSync('sha256sum', [stagedArchive.path]).stdout as String)
            .split(' ')
            .first;
    final artifact = ManifestArtifact(
      platform: 'linux',
      arch: 'x64',
      filename: 'notes-1.0.1-linux-x64.tar.gz',
      sha256: sha,
      size: stagedArchive.lengthSync(),
    );
    final candidate = UpdateCandidate(
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
        artifacts: [artifact],
      ),
      artifact: artifact,
      assetUrl: Uri.parse('https://example.test/x.tar.gz'),
      signed: true,
      platform: const UpdatePlatform(UpdateOs.linux, 'x64'),
    );
    return ReadyUpdate(candidate, stagedArchive);
  }

  Future<Map<String, dynamic>> waitForStatus(
    File statusFile,
    String phase,
  ) async {
    for (var i = 0; i < 100; i++) {
      if (statusFile.existsSync()) {
        final status =
            jsonDecode(statusFile.readAsStringSync()) as Map<String, dynamic>;
        if (status['phase'] == phase) return status;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('Timed out waiting for update status phase $phase.');
  }

  test('download -> helper -> new program passes the startup lock check', () async {
    final lockPath = '${stateBase()}/updater/lock';
    final newMarker = File('${temp.path}/new-startup');
    final archive = await makeArchive(
      startupScript(lockPath, newMarker.path, 'NEW'),
    );
    final data = File('${home.path}/.local/share/com.mmoptibuilds.notes/db')
      ..createSync(recursive: true);
    data.writeAsStringSync('synthetic encrypted data');

    // A short-lived stand-in for the running app: the helper must wait for it.
    final fakeApp = await Process.start('sleep', ['30']);
    var quit = false;
    final environment = {
      'HOME': home.path,
      'PATH': Platform.environment['PATH']!,
    };
    final installer = LinuxUpdateInstaller(
      onQuit: () async {
        quit = true;
        fakeApp.kill();
        await fakeApp.exitCode;
      },
      launcher: _EnvironmentLauncher(environment),
      environment: {'HOME': home.path},
      resolvedExecutable: '${install.path}/notes',
      currentPid: fakeApp.pid,
      tempRoot: temp,
      freeSpaceProbe: (_) async => 1 << 30,
      platform: const UpdatePlatform(UpdateOs.linux, 'x64'),
    );
    final info = await installer.prepare();
    expect(info.block, isNull);

    final result = await installer.install(await readyUpdate(archive), info);
    expect(result, isA<InstallHandedToOs>());
    expect(quit, isTrue);

    final status = File('${installer.stateDir}/update.json');
    final done = await waitForStatus(status, 'done');
    expect(done['ok'], isTrue);
    expect(done['toVersion'], '1.0.1');
    for (var i = 0; i < 50 && !newMarker.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(newMarker.existsSync(), isTrue);
    expect(newMarker.readAsStringSync().trim(), 'NEW');
    expect(File('${install.path}/notes').readAsStringSync(), contains('flock'));
    expect(Directory('${install.path}.previous').existsSync(), isTrue);
    expect(data.readAsStringSync(), 'synthetic encrypted data');
    expect(
      File('${install.path}/.managed-install').readAsStringSync(),
      contains('1.0.1'),
    );
  });

  Future<void> expectFailureRelaunch({
    required String expectedError,
    required Future<void> Function(Directory fakeBin) configureFailure,
    bool oldAppAtPrevious = false,
  }) async {
    final lockPath = '${stateBase()}/updater/lock';
    final oldMarker = File('${temp.path}/old-startup');
    File('${install.path}/notes')
        .writeAsStringSync(startupScript(lockPath, oldMarker.path, 'OLD'));
    final fakeBin = Directory('${temp.path}/fake-bin')..createSync();
    await configureFailure(fakeBin);
    final archive = await makeArchive('#!/bin/sh\necho NEW\n');

    final fakeApp = await Process.start('sleep', ['30']);
    final environment = {
      'HOME': home.path,
      'PATH': '${fakeBin.path}:${Platform.environment['PATH']!}',
    };
    final installer = LinuxUpdateInstaller(
      onQuit: () async {
        fakeApp.kill();
        await fakeApp.exitCode;
      },
      launcher: _EnvironmentLauncher(environment),
      environment: {'HOME': home.path},
      resolvedExecutable: '${install.path}/notes',
      currentPid: fakeApp.pid,
      tempRoot: temp,
      freeSpaceProbe: (_) async => 1 << 30,
      platform: const UpdatePlatform(UpdateOs.linux, 'x64'),
    );
    final info = await installer.prepare();
    expect(info.block, isNull);
    expect(
      await installer.install(await readyUpdate(archive), info),
      isA<InstallHandedToOs>(),
    );

    final status = await waitForStatus(
      File('${installer.stateDir}/update.json'),
      'failed',
    );
    expect(status['ok'], isFalse);
    expect(status['error'], expectedError);
    for (var i = 0; i < 50 && !oldMarker.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(oldMarker.existsSync(), isTrue);
    expect(oldMarker.readAsStringSync().trim(), 'OLD');
    final oldApp = File(
      oldAppAtPrevious
          ? '${install.path}.previous/notes'
          : '${install.path}/notes',
    );
    expect(oldApp.readAsStringSync(), contains('OLD'));

    final outcome = await installer.lastOutcome(info);
    expect(outcome, isNotNull);
    expect(outcome!.updated, isFalse);
    expect(outcome.message, contains(expectedError));
  }

  test(
    'low-space failure releases the lock and relaunches the old program',
    () async {
      await expectFailureRelaunch(
        expectedError: 'insufficient_space',
        configureFailure: (fakeBin) async {
          final fakeDf = File('${fakeBin.path}/df')
            ..writeAsStringSync('#!/bin/sh\nprintf "Avail\\n1\\n"\n');
          Process.runSync('chmod', ['+x', fakeDf.path]);
        },
      );
    },
  );

  test(
    'extraction failure releases the lock and relaunches the old program',
    () async {
      final realTar =
          (Process.runSync('sh', ['-c', 'command -v tar']).stdout as String)
              .trim();
      await expectFailureRelaunch(
        expectedError: 'verification_failed',
        configureFailure: (fakeBin) async {
          final fakeTar = File('${fakeBin.path}/tar')
            ..writeAsStringSync(
              '#!/bin/sh\n'
              'for arg do [ "\$arg" = -xzf ] && exit 1; done\n'
              'exec ${quote(realTar)} "\$@"\n',
            );
          Process.runSync('chmod', ['+x', fakeTar.path]);
        },
      );
    },
  );

  test('swap failure restores and relaunches the old program', () async {
    final realMv =
        (Process.runSync('sh', ['-c', 'command -v mv']).stdout as String)
            .trim();
    await expectFailureRelaunch(
      expectedError: 'second_rename_rolled_back',
      configureFailure: (fakeBin) async {
        final fakeMv = File('${fakeBin.path}/mv')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            'case "\$1" in *.notes-staging-*) exit 1;; esac\n'
            'exec ${quote(realMv)} "\$@"\n',
          );
        Process.runSync('chmod', ['+x', fakeMv.path]);
      },
    );
  });

  test(
    'failed rollback keeps and relaunches the old program from previous',
    () async {
      final realMv =
          (Process.runSync('sh', ['-c', 'command -v mv']).stdout as String)
              .trim();
      await expectFailureRelaunch(
        expectedError: 'rollback_failed',
        oldAppAtPrevious: true,
        configureFailure: (fakeBin) async {
          final fakeMv = File('${fakeBin.path}/mv')
            ..writeAsStringSync(
              '#!/bin/sh\n'
              'case "\$1" in *.notes-staging-*|*.previous) exit 1;; esac\n'
              'exec ${quote(realMv)} "\$@"\n',
            );
          Process.runSync('chmod', ['+x', fakeMv.path]);
        },
      );
    },
  );
}
