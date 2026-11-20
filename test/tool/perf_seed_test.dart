import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/perf/seed_library.dart' show seedLibrary;

void main() {
  test(
    'seed refuses a non-empty output and preserves an existing database',
    () {
      final root = Directory.systemTemp.createTempSync('notes seed safety ');
      addTearDown(() => root.deleteSync(recursive: true));
      final dataset = Directory('${root.path}/500')..createSync();
      final database = File('${dataset.path}/notes.db')
        ..writeAsStringSync('synthetic sentinel');

      expect(() => seedLibrary(root), throwsArgumentError);
      expect(database.readAsStringSync(), 'synthetic sentinel');
    },
  );
  test('seed refuses when the app data directory is inside the output', () {
    final root = Directory.systemTemp.createTempSync('notes seed inside ');
    addTearDown(() => root.deleteSync(recursive: true));
    final dataset = Directory('${root.path}/500')..createSync();
    final database = File('${dataset.path}/notes.db')
      ..writeAsStringSync('synthetic sentinel');
    File('${dataset.path}/dev.key').writeAsStringSync('k');

    expect(
      () => seedLibrary(
        root,
        forceEmptyTemp: true,
        dataDirOverride: dataset.path,
      ),
      throwsArgumentError,
    );
    expect(database.readAsStringSync(), 'synthetic sentinel');
  });
}
