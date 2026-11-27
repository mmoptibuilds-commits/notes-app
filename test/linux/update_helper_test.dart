import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const helper = 'tool/linux/notes-update-helper';

void main() {
  late Directory temp;
  late Directory home;
  late Directory install;
  late Directory state;
  late Directory archiveRoot;
  late File archive;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('notes-update-test-');
    home = Directory('${temp.path}/fake-home')..createSync();
    install = Directory('${home.path}/.local/opt/notes')
      ..createSync(recursive: true);
    state = Directory(
      '${home.path}/.local/state/com.mmoptibuilds.notes/updater',
    );
    File('${install.path}/.managed-install').writeAsStringSync(
      '{"schema":1,"version":"1.0.0","installedAt":"2026-01-01T00:00:00Z"}\n',
    );
    Directory('${install.path}/lib').createSync();
    Directory('${install.path}/data').createSync();
    File('${install.path}/notes').writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('chmod', ['+x', '${install.path}/notes']);
    archiveRoot = Directory('${temp.path}/notes-1.0.1-linux-x64')..createSync();
    Directory('${archiveRoot.path}/bundle/lib').createSync(recursive: true);
    Directory('${archiveRoot.path}/bundle/data').createSync(recursive: true);
    File('${archiveRoot.path}/bundle/data/sample file.txt')
        .writeAsStringSync('synthetic package data');
    Directory('${archiveRoot.path}/update').createSync();
    File(helper).copySync('${archiveRoot.path}/update/notes-update-helper');
    File('${archiveRoot.path}/bundle/notes')
        .writeAsStringSync('#!/bin/sh\necho updated\n');
    Process.runSync('chmod', ['+x', '${archiveRoot.path}/bundle/notes']);
    archive = File('${temp.path}/notes.tar.gz');
    Process.runSync('tar', [
      '-czf',
      archive.path,
      '-C',
      temp.path,
      _basename(archiveRoot.path),
    ]);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<ProcessResult> run({
    String version = '1.0.1',
    String? hash,
    int? size,
    bool relaunch = false,
    int? build,
    Map<String, String> env = const {},
    String? pathPrefix,
  }) async {
    final bytes = archive.readAsBytesSync();
    final checksum = hash ?? _sha256(bytes);
    return Process.run(
      '/bin/sh',
      [
        helper,
        'apply',
        '--pid',
        '99999999',
        '--archive',
        archive.path,
        '--sha256',
        checksum,
        '--size',
        '${size ?? bytes.length}',
        '--install',
        install.path,
        '--state-dir',
        state.path,
        '--version',
        version,
        if (build != null) ...['--build', '$build'],
        if (relaunch) '--relaunch',
      ],
      environment: {
        'HOME': home.path,
        'PATH':
            '${pathPrefix == null ? '' : '$pathPrefix:'}'
            '${Platform.environment['PATH']!}',
        ...env,
      },
    );
  }

  /// Rebuilds [archive] from [archiveRoot] plus one extra tar member made by
  /// python's tarfile (so hostile entries need no privileges to create).
  void archiveWith(String memberKind) {
    final script = r'''
import sys, tarfile, io
out, root, top, kind = sys.argv[1:5]
t = tarfile.open(out, 'w:gz')
t.add(root, arcname=top)
if kind == 'absolute':
    i = tarfile.TarInfo('/tmp/notes-evil-abs'); i.size = 1; t.addfile(i, io.BytesIO(b'x'))
elif kind == 'dotdot':
    i = tarfile.TarInfo(top + '/../notes-evil-dotdot'); i.size = 1; t.addfile(i, io.BytesIO(b'x'))
elif kind == 'hardlink':
    i = tarfile.TarInfo(top + '/bundle/hl'); i.type = tarfile.LNKTYPE; i.linkname = '../../outside'; t.addfile(i)
elif kind == 'hardlink_abs':
    i = tarfile.TarInfo(top + '/bundle/hl'); i.type = tarfile.LNKTYPE; i.linkname = '/etc/passwd'; t.addfile(i)
elif kind == 'symlink_abs':
    i = tarfile.TarInfo(top + '/bundle/sl'); i.type = tarfile.SYMTYPE; i.linkname = '/etc'; t.addfile(i)
elif kind == 'symlink_up':
    i = tarfile.TarInfo(top + '/bundle/sl'); i.type = tarfile.SYMTYPE; i.linkname = '../../..'; t.addfile(i)
elif kind == 'device':
    i = tarfile.TarInfo(top + '/bundle/dev'); i.type = tarfile.CHRTYPE; i.devmajor = 1; i.devminor = 3; t.addfile(i)
elif kind == 'fifo':
    i = tarfile.TarInfo(top + '/bundle/fifo'); i.type = tarfile.FIFOTYPE; t.addfile(i)
elif kind == 'setuid':
    i = tarfile.TarInfo(top + '/bundle/suid'); i.size = 1; i.mode = 0o4755; t.addfile(i, io.BytesIO(b'x'))
t.close()
''';
    final r = Process.runSync('python3', [
      '-c',
      script,
      archive.path,
      archiveRoot.path,
      _basename(archiveRoot.path),
      memberKind,
    ]);
    expect(r.exitCode, 0, reason: r.stderr.toString());
  }

  List<String> leftovers() => [
    for (final e in Directory('${home.path}/.local/opt').listSync())
      if (_basename(e.path).startsWith('.notes-')) e.path,
  ];

  test('fresh staged update preserves data and records status', () async {
    final data = File(
      '${home.path}/.local/share/com.mmoptibuilds.notes/sentinel',
    );
    data.parent.createSync(recursive: true);
    data.writeAsStringSync('synthetic user data');
    final result = await run();
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      File('${install.path}/notes').readAsStringSync(),
      contains('updated'),
    );
    expect(data.readAsStringSync(), 'synthetic user data');
    expect(
      File('${install.path}/data/sample file.txt').readAsStringSync(),
      'synthetic package data',
    );
    expect(
      File('${install.path}/.managed-install').readAsStringSync(),
      contains('1.0.1'),
    );
    final status = jsonDecode(
      File('${state.path}/update.json').readAsStringSync(),
    );
    expect(status['phase'], 'done');
    expect(status['ok'], isTrue);
    expect(Directory('${install.path}.previous').existsSync(), isTrue);
  });

  test(
    'low install-parent space leaves the current program untouched',
    () async {
      final fakeBin = Directory('${temp.path}/fake-bin')..createSync();
      final fakeDf = File('${fakeBin.path}/df')
        ..writeAsStringSync('#!/bin/sh\nprintf "Avail\\n1\\n"\n');
      Process.runSync('chmod', ['+x', fakeDf.path]);
      final result = await run(pathPrefix: fakeBin.path);
      expect(result.exitCode, 10, reason: result.stderr.toString());
      expect(result.stderr.toString(), contains('Not enough free space'));
      expect(
        File('${install.path}/notes').readAsStringSync(),
        contains('exit 0'),
      );
      expect(leftovers(), isEmpty);
      final status = jsonDecode(
        File('${state.path}/update.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(status['error'], 'insufficient_space');
    },
  );

  test('same version and downgrade are refused', () async {
    final same = await run(version: '1.0.0');
    expect(same.exitCode, 10);
    final lower = await run(version: '0.9.0');
    expect(lower.exitCode, 10);
    expect(
      File('${install.path}/notes').readAsStringSync(),
      contains('exit 0'),
    );
  });

  group('a previous install made by the first installer (no marker)', () {
    void legacyPrevious() {
      final prev = Directory('${install.path}.previous')..createSync();
      Directory('${prev.path}/lib').createSync();
      Directory('${prev.path}/data/flutter_assets').createSync(recursive: true);
      File('${prev.path}/notes').writeAsStringSync('#!/bin/sh\necho legacy\n');
      Process.runSync('chmod', ['+x', '${prev.path}/notes']);
    }

    test('does not block the next update', () async {
      legacyPrevious();
      final r = await run();
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(
        File('${install.path}.previous/notes').readAsStringSync(),
        contains('exit 0'),
        reason: 'the install being replaced is the new previous',
      );
    });

    test(
      'can be rolled back to, and gets a marker so updates keep working',
      () async {
        legacyPrevious();
        Process.runSync('rm', [
          '-rf',
          install.path,
        ]); // only previous remains...
        // Put a current install back, so rollback has something to swap out.
        Directory(install.path).createSync(recursive: true);
        Directory('${install.path}/lib').createSync();
        Directory('${install.path}/data').createSync();
        File('${install.path}/notes').writeAsStringSync('#!/bin/sh\nexit 0\n');
        Process.runSync('chmod', ['+x', '${install.path}/notes']);
        File('${install.path}/.managed-install').writeAsStringSync(
          '{"schema":1,"version":"1.0.1","build":5,"installedAt":"2026-01-01T00:00:00Z"}\n',
        );
        final r = await Process.run(
          '/bin/sh',
          [
            helper,
            'rollback',
            '--install',
            install.path,
            '--state-dir',
            state.path,
          ],
          environment: {
            'HOME': home.path,
            'PATH': Platform.environment['PATH']!,
          },
        );
        expect(r.exitCode, 0, reason: r.stderr.toString());
        expect(
          File('${install.path}/notes').readAsStringSync(),
          contains('echo legacy'),
        );
        expect(
          File('${install.path}/.managed-install').readAsStringSync(),
          contains('"version":"0.0.0"'),
        );
        final next = await run(version: '1.0.1', build: 1);
        expect(next.exitCode, 0, reason: next.stderr.toString());
      },
    );
  });

  group('the same version with a higher build is an update', () {
    void installedAs(
      int? build,
    ) => File('${install.path}/.managed-install').writeAsStringSync(
      '{"schema":1,"version":"1.0.1"${build == null ? '' : ',"build":$build'},'
      '"installedAt":"2026-01-01T00:00:00Z"}\n',
    );

    test('higher build is applied and recorded', () async {
      installedAs(5);
      final r = await run(build: 6);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(
        File('${install.path}/.managed-install').readAsStringSync(),
        contains('"build":6'),
      );
    });

    test('the same or a lower build is refused', () async {
      installedAs(5);
      expect((await run(build: 5)).exitCode, 10);
      expect((await run(build: 4)).exitCode, 10);
      expect(
        File('${install.path}/notes').readAsStringSync(),
        contains('exit 0'),
      );
    });

    test('an install recorded without a build counts as build 0', () async {
      installedAs(null);
      expect((await run()).exitCode, 10, reason: 'no build given = 0');
      expect((await run(build: 1)).exitCode, 0);
    });

    test('a higher version wins whatever the builds are', () async {
      File('${install.path}/.managed-install').writeAsStringSync(
        '{"schema":1,"version":"1.0.0","build":900,'
        '"installedAt":"2026-01-01T00:00:00Z"}\n',
      );
      final r = await run(version: '1.0.1', build: 1);
      expect(r.exitCode, 0, reason: r.stderr.toString());
    });
  });

  test('wrong digest and size fail before replacing the install', () async {
    final wrongHash = await run(hash: List.filled(64, '0').join());
    expect(wrongHash.exitCode, 11);
    final wrongSize = await run(size: archive.lengthSync() + 1);
    expect(wrongSize.exitCode, 11);
    expect(
      File('${install.path}/notes').readAsStringSync(),
      contains('exit 0'),
    );
  });

  test('unmanaged install is refused', () async {
    File('${install.path}/.managed-install').deleteSync();
    final result = await run();
    expect(result.exitCode, 10);
  });

  test(
    'corrupt and unsafe archives are rejected without replacing files',
    () async {
      archive.writeAsStringSync('not a gzip archive');
      final corrupt = await run();
      expect(corrupt.exitCode, 11);

      final link = Link('${archiveRoot.path}/escape')
        ..createSync('../../outside');
      Process.runSync('tar', [
        '-czf',
        archive.path,
        '-C',
        temp.path,
        _basename(archiveRoot.path),
      ]);
      final unsafe = await run();
      expect(unsafe.exitCode, 11);
      expect(
        FileSystemEntity.typeSync(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(
        File('${install.path}/notes').readAsStringSync(),
        contains('exit 0'),
      );
    },
  );

  test('missing runtime files are rejected', () async {
    Directory('${archiveRoot.path}/bundle/data').deleteSync(recursive: true);
    Process.runSync('tar', [
      '-czf',
      archive.path,
      '-C',
      temp.path,
      _basename(archiveRoot.path),
    ]);
    final result = await run();
    expect(result.exitCode, 11);
    expect(
      File('${install.path}/notes').readAsStringSync(),
      contains('exit 0'),
    );
  });

  test(
    'interrupted first rename is recovered before applying update',
    () async {
      Directory('${install.path}.previous').createSync();
      File('${install.path}.previous/.managed-install')
          .writeAsStringSync('{"schema":1,"version":"1.0.0"}\n');
      File('${install.path}.previous/notes')
          .writeAsStringSync('#!/bin/sh\nexit 0\n');
      Process.runSync('chmod', ['+x', '${install.path}.previous/notes']);
      Directory(install.path).deleteSync(recursive: true);
      final result = await run();
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(
        File('${install.path}/.managed-install').readAsStringSync(),
        contains('1.0.1'),
      );
    },
  );

  test('process executing from install blocks replacement', () async {
    // A real executable inside the install. A shell is used (not sleep): on
    // some distributions sleep is a multi-call binary that exits when renamed.
    File('/bin/sh').copySync('${install.path}/notes');
    Process.runSync('chmod', ['+x', '${install.path}/notes']);
    final running = await Process.start('${install.path}/notes', [
      '-c',
      'sleep 10; true',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final result = await run();
    running.kill();
    await running.exitCode;
    expect(result.exitCode, 10);
    expect(result.stderr.toString(), contains('process is still running'));
  });

  test('exclusive state lock returns busy exit code', () async {
    state.createSync(recursive: true);
    final lock = File('${state.path}/lock')..createSync();
    final holder = await Process.start('flock', [
      '-x',
      lock.path,
      'sleep',
      '3',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final result = await run();
    holder.kill();
    await holder.exitCode;
    expect(result.exitCode, 12);
  });

  group('hostile archives are refused before anything is replaced', () {
    for (final kind in [
      'absolute',
      'dotdot',
      'hardlink',
      'hardlink_abs',
      'symlink_abs',
      'symlink_up',
      'device',
      'fifo',
      'setuid',
    ]) {
      test(kind, () async {
        archiveWith(kind);
        final result = await run();
        expect(result.exitCode, 11, reason: result.stderr.toString());
        expect(
          result.stderr,
          contains('Unsafe archive entries or unexpected layout'),
        );
        expect(
          File('${install.path}/notes').readAsStringSync(),
          contains('exit 0'),
          reason: 'the live install is untouched',
        );
        expect(Directory('${install.path}.previous').existsSync(), isFalse);
        expect(leftovers(), isEmpty, reason: 'no staging debris');
        final status = jsonDecode(
          File('${state.path}/update.json').readAsStringSync(),
        );
        expect(status['ok'], isFalse);
        expect(status['phase'], 'failed');
        expect(status['error'], 'verification_failed');
        // Nothing escaped the archive: no files outside the fake home.
        expect(File('${temp.path}/notes-evil-dotdot').existsSync(), isFalse);
        expect(File('/tmp/notes-evil-abs').existsSync(), isFalse);
      });
    }
  });

  group('swap failures', () {
    late String realMv;
    late Directory fakeBin;
    setUp(() {
      realMv = (Process.runSync('sh', ['-c', 'command -v mv']).stdout as String)
          .trim();
      fakeBin = Directory('${temp.path}/fakebin')..createSync();
    });

    void fakeMv(String body) {
      final f = File('${fakeBin.path}/mv')
        ..writeAsStringSync('#!/bin/sh\n$body\nexec $realMv "\$@"\n');
      Process.runSync('chmod', ['+x', f.path]);
    }

    test('second rename fails: the previous install is put back', () async {
      // Fail only the move of the staging directory into place.
      fakeMv(r'case "$1" in *.notes-staging-*) exit 1;; esac');
      final result = await run(pathPrefix: fakeBin.path);
      expect(result.exitCode, 14, reason: result.stderr.toString());
      expect(
        File('${install.path}/notes').readAsStringSync(),
        contains('exit 0'),
        reason: 'the old program is back in place',
      );
      expect(Directory('${install.path}.previous').existsSync(), isFalse);
      final status = jsonDecode(
        File('${state.path}/update.json').readAsStringSync(),
      );
      expect(status['ok'], isFalse);
      expect(status['error'], 'second_rename_rolled_back');
    });

    test('rollback itself fails: reported, nothing is deleted', () async {
      fakeMv(r'case "$1" in *.notes-staging-*|*.previous) exit 1;; esac');
      final result = await run(pathPrefix: fakeBin.path);
      expect(result.exitCode, 15, reason: result.stderr.toString());
      // The old program survives as install.previous for manual recovery.
      expect(
        File('${install.path}.previous/notes').readAsStringSync(),
        contains('exit 0'),
      );
      final status = jsonDecode(
        File('${state.path}/update.json').readAsStringSync(),
      );
      expect(status['error'], 'rollback_failed');
    });

    test('the next run recovers an interrupted swap', () async {
      fakeMv(r'case "$1" in *.notes-staging-*|*.previous) exit 1;; esac');
      await run(pathPrefix: fakeBin.path); // leaves only install.previous
      expect(install.existsSync(), isFalse);
      final again = await run(); // a normal run first restores, then updates
      expect(again.exitCode, 0, reason: again.stderr.toString());
      expect(
        File('${install.path}/notes').readAsStringSync(),
        contains('updated'),
      );
    });
  });

  test('--relaunch starts the new program after a successful swap', () async {
    File(
      '${archiveRoot.path}/bundle/notes',
    ).writeAsStringSync('#!/bin/sh\necho relaunched > "\$NOTES_TEST_MARK"\n');
    Process.runSync('chmod', ['+x', '${archiveRoot.path}/bundle/notes']);
    Process.runSync('tar', [
      '-czf',
      archive.path,
      '-C',
      temp.path,
      _basename(archiveRoot.path),
    ]);
    final mark = File('${temp.path}/relaunch-mark');
    final result = await run(
      relaunch: true,
      env: {'NOTES_TEST_MARK': mark.path},
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());
    for (var i = 0; i < 40 && !mark.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(mark.existsSync(), isTrue);
    expect(mark.readAsStringSync().trim(), 'relaunched');
  });

  test('a rollback command restores the previous program', () async {
    expect((await run()).exitCode, 0);
    final r = await Process.run(
      '/bin/sh',
      [
        helper,
        'rollback',
        '--install',
        install.path,
        '--state-dir',
        state.path,
      ],
      environment: {'HOME': home.path, 'PATH': Platform.environment['PATH']!},
    );
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(
      File('${install.path}/notes').readAsStringSync(),
      contains('exit 0'),
    );
    expect(
      File('${install.path}/.managed-install').readAsStringSync(),
      contains('1.0.0'),
    );
  });
}

String _sha256(List<int> bytes) {
  // Test-side SHA-256 is provided by the existing crypto dependency.
  // This synchronous helper uses the platform sha256sum command instead.
  final dir = Directory.systemTemp.createTempSync('notes-hash-');
  try {
    final file = File('${dir.path}/artifact')..writeAsBytesSync(bytes);
    return (Process.runSync('sha256sum', [file.path]).stdout as String)
        .split(' ')
        .first;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;
