import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Directory home;
  late Directory package;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('notes-install-test-');
    home = Directory('${temp.path}/fake-home')..createSync();
    package = Directory('${temp.path}/notes-1.0.1-linux-x64')..createSync();
    Directory('${package.path}/bundle/lib').createSync(recursive: true);
    Directory('${package.path}/bundle/data').createSync(recursive: true);
    File('${package.path}/bundle/notes')
        .writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('chmod', ['+x', '${package.path}/bundle/notes']);
    File('${package.path}/install.sh')
        .writeAsStringSync(File('tool/linux/install.sh').readAsStringSync());
    File('${package.path}/uninstall.sh')
        .writeAsStringSync(File('tool/linux/uninstall.sh').readAsStringSync());
    Directory('${package.path}/update').createSync();
    File('tool/linux/notes-update-helper')
        .copySync('${package.path}/update/notes-update-helper');
    File('${package.path}/notes.png').writeAsStringSync('synthetic icon');
    File('${package.path}/com.mmoptibuilds.notes.desktop')
        .writeAsStringSync('[Desktop Entry]\nName=Notes\n');
    Process.runSync('chmod', [
      '+x',
      '${package.path}/install.sh',
      '${package.path}/uninstall.sh',
    ]);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('install and upgrade preserve data and refresh launcher and icon', () async {
    final userData = File(
      '${home.path}/.local/share/com.mmoptibuilds.notes/sentinel',
    );
    userData.parent.createSync(recursive: true);
    userData.writeAsStringSync('synthetic data');
    Future<ProcessResult> install() => Process.run(
      '${package.path}/install.sh',
      [],
      environment: {'HOME': home.path, 'PATH': Platform.environment['PATH']!},
    );

    final first = await install();
    expect(first.exitCode, 0, reason: first.stderr.toString());
    final program = Directory('${home.path}/.local/opt/notes');
    expect(
      File('${program.path}/.managed-install').readAsStringSync(),
      contains('1.0.1'),
    );
    expect(
      File('${program.path}/update/notes-update-helper').existsSync(),
      isTrue,
    );
    expect(File('${home.path}/.local/bin/notes').existsSync(), isTrue);
    expect(
      File(
        '${home.path}/.local/share/applications/com.mmoptibuilds.notes.desktop',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '${home.path}/.local/share/icons/hicolor/512x512/apps/com.mmoptibuilds.notes.png',
      ).existsSync(),
      isTrue,
    );
    expect(userData.readAsStringSync(), 'synthetic data');

    File('${package.path}/bundle/notes')
        .writeAsStringSync('#!/bin/sh\necho new\n');
    final second = await install();
    expect(second.exitCode, 0, reason: second.stderr.toString());
    expect(
      File('${program.path}/notes').readAsStringSync(),
      contains('echo new'),
    );
    expect(userData.readAsStringSync(), 'synthetic data');

    final removed = await Process.run(
      '${package.path}/uninstall.sh',
      [],
      environment: {'HOME': home.path, 'PATH': Platform.environment['PATH']!},
    );
    expect(removed.exitCode, 0);
    expect(program.existsSync(), isFalse);
    expect(userData.readAsStringSync(), 'synthetic data');
    expect(removed.stdout.toString(), contains('Your notes were not deleted'));
  });

  Map<String, String> env() => {
    'HOME': home.path,
    'PATH': Platform.environment['PATH']!,
  };

  Directory legacyInstall() {
    // What the first installer left: no marker, no update helper.
    final d = Directory('${home.path}/.local/opt/notes')
      ..createSync(recursive: true);
    Directory('${d.path}/lib').createSync();
    Directory('${d.path}/data/flutter_assets').createSync(recursive: true);
    File('${d.path}/notes').writeAsStringSync('#!/bin/sh\necho legacy\n');
    Process.runSync('chmod', ['+x', '${d.path}/notes']);
    return d;
  }

  test(
    'a baseline-format install (no marker) is adopted and upgraded',
    () async {
      File('${package.path}/BUILD').writeAsStringSync('20261122\n');
      final userData = File(
        '${home.path}/.local/share/com.mmoptibuilds.notes/sentinel',
      )..createSync(recursive: true);
      userData.writeAsStringSync('synthetic data');
      final legacy = legacyInstall();
      final r = await Process.run(
        '${package.path}/install.sh',
        [],
        environment: env(),
      );
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final marker = File('${legacy.path}/.managed-install').readAsStringSync();
      expect(marker, contains('"version":"1.0.1"'));
      expect(marker, contains('"build":20261122'));
      expect(
        File('${legacy.path}/update/notes-update-helper').existsSync(),
        isTrue,
      );
      expect(
        File('${legacy.path}.previous/notes').readAsStringSync(),
        contains('echo legacy'),
        reason: 'the old program is kept for recovery',
      );
      expect(userData.readAsStringSync(), 'synthetic data');
    },
  );

  test('something that is not a Notes install is never replaced', () async {
    final other = Directory('${home.path}/.local/opt/notes')
      ..createSync(recursive: true);
    final keep = File('${other.path}/precious')..writeAsStringSync('keep me');
    final r = await Process.run(
      '${package.path}/install.sh',
      [],
      environment: env(),
    );
    expect(r.exitCode, 10);
    expect(keep.readAsStringSync(), 'keep me');
    expect(Directory('${other.path}.previous').existsSync(), isFalse);
  });

  test('a symlink at the install path is refused', () async {
    final target = Directory('${temp.path}/elsewhere')..createSync();
    File('${target.path}/precious').writeAsStringSync('keep me');
    Directory('${home.path}/.local/opt').createSync(recursive: true);
    Link('${home.path}/.local/opt/notes').createSync(target.path);
    final r = await Process.run(
      '${package.path}/install.sh',
      [],
      environment: env(),
    );
    expect(r.exitCode, 10);
    expect(File('${target.path}/precious').readAsStringSync(), 'keep me');
  });

  group('uninstall', () {
    test(
      'refuses a directory that is not a Notes install, changing nothing',
      () async {
        final other = Directory('${home.path}/.local/opt/notes')
          ..createSync(recursive: true);
        final keep = File('${other.path}/precious')
          ..writeAsStringSync('keep me');
        final launcher = File('${home.path}/.local/bin/notes')
          ..createSync(recursive: true);
        final r = await Process.run(
          '${package.path}/uninstall.sh',
          [],
          environment: env(),
        );
        expect(r.exitCode, 10);
        expect(
          r.stderr.toString(),
          contains('does not look like an installed copy'),
        );
        expect(keep.readAsStringSync(), 'keep me');
        expect(
          launcher.existsSync(),
          isTrue,
          reason: 'nothing else was touched',
        );
      },
    );

    test('refuses a symlink', () async {
      final target = Directory('${temp.path}/elsewhere')..createSync();
      File('${target.path}/precious').writeAsStringSync('keep me');
      Directory('${home.path}/.local/opt').createSync(recursive: true);
      Link('${home.path}/.local/opt/notes').createSync(target.path);
      final r = await Process.run(
        '${package.path}/uninstall.sh',
        [],
        environment: env(),
      );
      expect(r.exitCode, 10);
      expect(File('${target.path}/precious').readAsStringSync(), 'keep me');
    });

    test('removes a baseline-format install and keeps the data', () async {
      final userData = File(
        '${home.path}/.local/share/com.mmoptibuilds.notes/sentinel',
      )..createSync(recursive: true);
      userData.writeAsStringSync('synthetic data');
      final legacy = legacyInstall();
      final r = await Process.run(
        '${package.path}/uninstall.sh',
        [],
        environment: env(),
      );
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(legacy.existsSync(), isFalse);
      expect(userData.readAsStringSync(), 'synthetic data');
    });
  });
}
