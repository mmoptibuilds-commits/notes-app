import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/importer/atomic_export.dart';

void main() {
  test(
    'a failed temp write keeps the previous export and removes the temp',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'notes atomic export ',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final target = File('${directory.path}/notes.json')
        ..writeAsStringSync('old export');

      await expectLater(
        writeExportAtomically(
          target,
          'new export',
          writeTemporary: (temporary, _) async {
            await temporary.writeAsString('partial export', flush: true);
            throw StateError('injected disk failure');
          },
        ),
        throwsStateError,
      );

      expect(await target.readAsString(), 'old export');
      expect(directory.listSync().map((entity) => entity.path).toSet(), {
        target.path,
      });
    },
  );

  test(
    'a successful write replaces the target and leaves no temp file',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'notes atomic export ',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final target = File('${directory.path}/notes.json')
        ..writeAsStringSync('old export');

      await writeExportAtomically(target, 'new export');

      expect(await target.readAsString(), 'new export');
      expect(directory.listSync().map((entity) => entity.path).toSet(), {
        target.path,
      });
    },
  );
}
