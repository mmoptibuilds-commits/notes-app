import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/perf/seed_library.dart' show seedLibrary;

/// Generates the synthetic performance datasets (`empty`, `50`, `500`,
/// `large`) into an empty directory. The seed tool imports the app's database
/// code, which needs the Flutter test runner, so it is driven from here:
///
///     NOTES_PERF_SEED_DIR=$(mktemp -d) flutter test test/perf/seed_datasets_test.dart
void main() {
  final dir = Platform.environment['NOTES_PERF_SEED_DIR'];
  test(
    'seed synthetic datasets into NOTES_PERF_SEED_DIR',
    () => seedLibrary(Directory(dir!)),
    skip: dir == null ? 'set NOTES_PERF_SEED_DIR to an empty directory' : false,
  );
}
