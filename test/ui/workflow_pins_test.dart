import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every GitHub Actions workflow use is pinned to a full SHA', () {
    final workflows = Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.yml'));
    expect(workflows, isNotEmpty);

    for (final workflow in workflows) {
      for (final line in workflow.readAsLinesSync()) {
        final trimmed = line.trimLeft();
        if (!trimmed.startsWith('uses:')) continue;
        final match = RegExp(r'^uses:\s*([^\s#]+)\s+#\s*v\d+\s*$')
            .firstMatch(trimmed);
        expect(match, isNotNull, reason: '${workflow.path}: $line');
        expect(
          match!.group(1),
          matches(RegExp(r'^[^/@\s]+/[^@\s]+@[0-9a-fA-F]{40}$')),
          reason: '${workflow.path}: $line',
        );
      }
    }
  });
}
