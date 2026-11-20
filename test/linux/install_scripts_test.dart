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
}
