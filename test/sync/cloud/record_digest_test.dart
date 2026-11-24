import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/cloud/record_digest.dart';

void main() {
  test('canonical object key order matches the shared SHA-256 vector', () {
    expect(
      recordDigest({'b': 2, 'a': 1}),
      '43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777',
    );
  });

  test('nested maps are sorted and arrays preserve order', () {
    expect(
      recordDigest({
        'z': [1, 2],
        'a': {'y': true, 'x': null},
      }),
      'fe68af9614f4a882a5892f71b17c7c107945dfaec1c43e3d93c3c9a04c0176e2',
    );
    expect(
      recordDigest({
        'z': [2, 1],
        'a': {'x': null, 'y': true},
      }),
      isNot(
        recordDigest({
          'z': [1, 2],
          'a': {'y': true, 'x': null},
        }),
      ),
    );
  });
}
