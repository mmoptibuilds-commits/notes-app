import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/bootstrap.dart';

void main() {
  test(
    'the shared lock blocks startup until the swap holder releases it',
    () async {
      final shell = await Process.run('/bin/sh', [
        'test/linux/update_lock_test.sh',
      ]);
      expect(shell.exitCode, 0, reason: shell.stderr.toString());

      final temp = await Directory.systemTemp.createTemp('notes-update-lock-');
      try {
        Directory('${temp.path}/updater').createSync();
        final lock = File('${temp.path}/updater/lock');
        final holder = await Process.start('flock', [
          '-n',
          lock.path,
          '/bin/sh',
          '-c',
          'sleep 0.2',
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final watch = Stopwatch()..start();
        await waitForUpdateSwapLock(lock, timeout: const Duration(seconds: 3));
        await holder.exitCode;
        expect(
          watch.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 100)),
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
