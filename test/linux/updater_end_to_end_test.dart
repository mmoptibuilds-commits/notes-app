import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/update/github_release_client.dart';
import 'package:notes/update/installer.dart';
import 'package:notes/update/linux_installer.dart';
import 'package:notes/update/manifest.dart';

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

  test('download -> helper -> new program in place, data untouched', () async {
    // A synthetic 1.0.1 package.
    final root = Directory('${temp.path}/notes-1.0.1-linux-x64')..createSync();
    Directory('${root.path}/bundle/lib').createSync(recursive: true);
    Directory('${root.path}/bundle/data').createSync(recursive: true);
    Directory('${root.path}/update').createSync();
    File('tool/linux/notes-update-helper')
        .copySync('${root.path}/update/notes-update-helper');
    File('${root.path}/bundle/notes')
        .writeAsStringSync('#!/bin/sh\necho NEW\n');
    Process.runSync('chmod', ['+x', '${root.path}/bundle/notes']);
    final stateBase = '${home.path}/.local/state/com.mmoptibuilds.notes';
    final updates = Directory('$stateBase/updates')
      ..createSync(recursive: true);
    final archive = File('${updates.path}/notes-1.0.1-linux-x64.tar.gz');
    final tar = Process.runSync('tar', [
      '-czf',
      archive.path,
      '-C',
      temp.path,
      'notes-1.0.1-linux-x64',
    ]);
    expect(tar.exitCode, 0);
    final sha = (Process.runSync('sha256sum', [archive.path]).stdout as String)
        .split(' ')
        .first;
    final data = File('${home.path}/.local/share/com.mmoptibuilds.notes/db')
      ..createSync(recursive: true);
    data.writeAsStringSync('synthetic encrypted data');

    // A short-lived stand-in for the running app: the helper must wait for it.
    final fakeApp = await Process.start('sleep', ['1']);
    var quit = false;
    final installer = LinuxUpdateInstaller(
      onQuit: () async => quit = true,
      environment: {'HOME': home.path},
      resolvedExecutable: '${install.path}/notes',
      currentPid: fakeApp.pid,
      tempRoot: temp,
      freeSpaceProbe: (_) async => 1 << 30,
      platform: const UpdatePlatform(UpdateOs.linux, 'x64'),
    );
    final info = await installer.prepare();
    expect(info.block, isNull);

    final artifact = ManifestArtifact(
      platform: 'linux',
      arch: 'x64',
      filename: 'notes-1.0.1-linux-x64.tar.gz',
      sha256: sha,
      size: archive.lengthSync(),
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
    final result = await installer.install(
      ReadyUpdate(candidate, archive),
      info,
    );
    expect(result, isA<InstallHandedToOs>());
    expect(quit, isTrue);

    final status = File('${installer.stateDir}/update.json');
    for (var i = 0; i < 100; i++) {
      if (status.existsSync() &&
          (jsonDecode(status.readAsStringSync()) as Map)['phase'] == 'done') {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final done = jsonDecode(status.readAsStringSync()) as Map<String, dynamic>;
    expect(done['phase'], 'done', reason: '$done');
    expect(done['ok'], isTrue);
    expect(done['toVersion'], '1.0.1');
    expect(File('${install.path}/notes').readAsStringSync(), contains('NEW'));
    expect(Directory('${install.path}.previous').existsSync(), isTrue);
    expect(data.readAsStringSync(), 'synthetic encrypted data');
    expect(
      File('${install.path}/.managed-install').readAsStringSync(),
      contains('1.0.1'),
    );
  });
}
