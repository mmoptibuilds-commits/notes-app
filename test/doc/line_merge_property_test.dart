import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/doc/checklist_projection.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/doc/line_merge.dart';

typedef Line = List<Map<String, dynamic>>;

String body(List<Line> lines) =>
    jsonEncode([for (final line in lines) ...line]);

List<Line> paragraphLines(List<String> values) => [
  for (final value in values)
    [
      {'insert': '$value\n'},
    ],
];

List<Line> readLines(String source) {
  final result = <Line>[];
  var current = <Map<String, dynamic>>[];
  for (final op in decodeOps(source)) {
    final insert = op['insert'];
    if (insert is String) {
      var start = 0;
      while (true) {
        final nl = insert.indexOf('\n', start);
        if (nl < 0) {
          if (start < insert.length) {
            current.add({
              'insert': insert.substring(start),
              if (op['attributes'] != null) 'attributes': op['attributes'],
            });
          }
          break;
        }
        if (nl > start) {
          current.add({
            'insert': insert.substring(start, nl),
            if (op['attributes'] != null) 'attributes': op['attributes'],
          });
        }
        current.add({
          'insert': '\n',
          if (op['attributes'] != null) 'attributes': op['attributes'],
        });
        result.add(current);
        current = <Map<String, dynamic>>[];
        start = nl + 1;
      }
    } else {
      current.add(op);
    }
  }
  return result;
}

String lineKey(Line line) => jsonEncode(line);
List<String> keys(String source) => readLines(source).map(lineKey).toList();

String randomLine(Random random, int id) {
  const words = [
    'para',
    'heading',
    '• bullet',
    '1. ordered',
    '☐ task',
    'quote',
    'code',
    'link',
    'image',
    'unknown',
    '',
    'emoji 😀',
    'combining e\u0301',
    'carriage\rreturn',
    'long',
  ];
  final word = words[random.nextInt(words.length)];
  return '$word/$id';
}

void checkValid(String merged, String reason) {
  final delta = deltaFromBody(merged);
  final allText = delta
      .toList()
      .map((op) => op.data)
      .whereType<String>()
      .join();
  expect(allText, endsWith('\n'), reason: reason);
  final split = ChecklistProjection.split(delta);
  expect(
    split.projection.merge(split.visible).toJson(),
    delta.toJson(),
    reason: reason,
  );
}

void main() {
  test('seeded identity and symmetry properties', () {
    const seed = 0x51a7;
    final random = Random(seed);
    for (var iteration = 0; iteration < 400; iteration++) {
      final count = 1 + random.nextInt(60);
      final baseLines = List.generate(count, (i) => 'base-$iteration-$i');
      final aLines = [...baseLines];
      final bLines = [...baseLines];
      final aAt = random.nextInt(count);
      final bAt = random.nextInt(count);
      aLines[aAt] = 'a-$iteration-$aAt';
      bLines[bAt] = bAt == aAt ? aLines[aAt] : 'b-$iteration-$bAt';
      final base = body(paragraphLines(baseLines));
      final a = body(paragraphLines(aLines));
      final b = body(paragraphLines(bLines));
      final same = mergeBodies(base, a, a);
      final unchanged = mergeBodies(base, base, a);
      final ab = mergeBodies(base, a, b);
      final ba = mergeBodies(base, b, a);
      final repro = 'seed=$seed iteration=$iteration base=$base a=$a b=$b';
      expect(same.isConflict, isFalse, reason: repro);
      expect(keys(same.body!), keys(a), reason: repro);
      expect(unchanged.isConflict, isFalse, reason: repro);
      expect(keys(unchanged.body!), keys(a), reason: repro);
      expect(ab.isConflict, ba.isConflict, reason: repro);
      if (!ab.isConflict) expect(keys(ab.body!), keys(ba.body!), reason: repro);
    }
  });

  test('identity property also holds at the 3,000-line document bound', () {
    const seed = 0x5c28;
    final baseLines = List.generate(3000, (i) => 'line-$i');
    final changedLines = [...baseLines]..[1500] = 'changed-at-1500';
    final base = body(paragraphLines(baseLines));
    final changed = body(paragraphLines(changedLines));
    final same = mergeBodies(base, changed, changed);
    final oneSided = mergeBodies(base, base, changed);
    expect(same.isConflict, isFalse, reason: 'seed=$seed');
    expect(oneSided.isConflict, isFalse, reason: 'seed=$seed');
    expect(keys(same.body!), keys(changed), reason: 'seed=$seed');
    expect(keys(oneSided.body!), keys(changed), reason: 'seed=$seed');
  });

  test(
    'seeded disjoint replacements preserve every untouched line in order',
    () {
      const seed = 0x6d3a;
      final random = Random(seed);
      for (var iteration = 0; iteration < 450; iteration++) {
        final count = 3 + random.nextInt(100);
        final base = List.generate(count, (i) => 'seed$seed-$iteration-$i');
        final first = random.nextInt(count);
        var second = random.nextInt(count - 1);
        if (second >= first) second++;
        final left = [...base]..[first] = 'LEFT-$iteration-$first';
        final right = [...base]..[second] = 'RIGHT-$iteration-$second';
        final merged = mergeBodies(
          body(paragraphLines(base)),
          body(paragraphLines(left)),
          body(paragraphLines(right)),
        );
        final repro =
            'seed=$seed iteration=$iteration first=$first second=$second';
        expect(merged.isConflict, isFalse, reason: repro);
        final expected = [...base]
          ..[first] = left[first]
          ..[second] = right[second];
        expect(
          keys(merged.body!),
          keys(body(paragraphLines(expected))),
          reason: repro,
        );
        checkValid(merged.body!, repro);
      }
    },
  );

  test('seeded non-overlapping deletions and insertions are both retained', () {
    const seed = 0x118b;
    final random = Random(seed);
    for (var iteration = 0; iteration < 250; iteration++) {
      final count = 3 + random.nextInt(40);
      final base = List.generate(count, (i) => 'base-$iteration-$i');
      final deletedAt = random.nextInt(count);
      final insertedAt = random.nextInt(count + 1);
      final local = [...base]..removeAt(deletedAt);
      final remote = [...base]..insert(insertedAt, 'insert-$iteration');
      final expected = <String>[];
      for (var i = 0; i <= count; i++) {
        if (i == insertedAt) expected.add('insert-$iteration');
        if (i < count && i != deletedAt) expected.add(base[i]);
      }
      final merged = mergeBodies(
        body(paragraphLines(base)),
        body(paragraphLines(local)),
        body(paragraphLines(remote)),
      );
      final repro =
          'seed=$seed iteration=$iteration delete=$deletedAt insert=$insertedAt';
      expect(merged.isConflict, isFalse, reason: repro);
      expect(
        keys(merged.body!),
        keys(body(paragraphLines(expected))),
        reason: repro,
      );
      checkValid(merged.body!, repro);
    }
  });

  test(
    'random line forms, embeds and long lines survive independent edits',
    () {
      const seed = 0x3b91;
      final random = Random(seed);
      final blockAttrs = <Map<String, dynamic>>[
        {},
        {'header': 1},
        {'list': 'bullet'},
        {'list': 'ordered'},
        {'list': 'unchecked'},
        {'list': 'checked'},
        {'blockquote': true},
        {'code-block': true},
      ];
      for (var iteration = 0; iteration < 180; iteration++) {
        final count = 3 + random.nextInt(20);
        final base = <Line>[];
        for (var i = 0; i < count; i++) {
          final value = randomLine(random, iteration * 100 + i);
          final attrs = blockAttrs[random.nextInt(blockAttrs.length)];
          final line = <Map<String, dynamic>>[
            if (i % 11 == 0)
              {
                'insert': 'https://example.invalid/$i',
                'attributes': {'link': 'https://example.invalid'},
              },
            if (i % 13 == 0)
              {
                'insert': {'image': 'fake-image-$i'},
              },
            if (i % 17 == 0)
              {
                'insert': {
                  'custom': {'id': i},
                },
              },
            if (value.isNotEmpty)
              {
                'insert': value,
                if (i % 7 == 0) 'attributes': {'bold': true},
              },
            {'insert': '\n', if (attrs.isNotEmpty) 'attributes': attrs},
          ];
          base.add(line);
        }
        if (iteration % 5 == 0) {
          base[0] = [
            {'insert': '${'x' * (1000 + iteration)}\r'},
            {'insert': '\n'},
          ];
          base.insert(1, [
            {'insert': '😀e\u0301'},
            {'insert': '\n'},
          ]);
        }
        final i = random.nextInt(count);
        var j = random.nextInt(count - 1);
        if (j >= i) j++;
        final left = [...base]
          ..[i] = paragraphLines(['left-$iteration-$i']).single;
        final right = [...base]
          ..[j] = paragraphLines(['right-$iteration-$j']).single;
        final merged = mergeBodies(body(base), body(left), body(right));
        final repro = 'seed=$seed iteration=$iteration base=${body(base)}';
        expect(merged.isConflict, isFalse, reason: repro);
        final expected = [...base]
          ..[i] = left[i]
          ..[j] = right[j];
        expect(keys(merged.body!), keys(body(expected)), reason: repro);
        checkValid(merged.body!, repro);
      }
    },
  );

  test('same-line edits conflict and arbitrary overlap is never cleanly lossy', () {
    const seed = 0x274a;
    final random = Random(seed);
    for (var iteration = 0; iteration < 350; iteration++) {
      final count = 2 + random.nextInt(24);
      final base = List.generate(count, (i) => 'b-$iteration-$i');
      final i = random.nextInt(count);
      final left = [...base]..[i] = 'l-$iteration-$i';
      final right = [...base]..[i] = 'r-$iteration-$i';
      final conflict = mergeBodies(
        body(paragraphLines(base)),
        body(paragraphLines(left)),
        body(paragraphLines(right)),
      );
      expect(
        conflict.isConflict,
        isTrue,
        reason: 'seed=$seed iteration=$iteration',
      );

      final x = List.generate(
        random.nextInt(5),
        (_) => randomLine(random, random.nextInt(100000)),
      );
      final y = List.generate(
        random.nextInt(5),
        (_) => randomLine(random, random.nextInt(100000)),
      );
      final arbitrary = mergeBodies(
        body(paragraphLines(base)),
        body(paragraphLines(x)),
        body(paragraphLines(y)),
      );
      if (!arbitrary.isConflict) {
        final out = keys(arbitrary.body!);
        final reason =
            'seed=$seed iteration=$iteration base=$base x=$x y=$y output=$out';
        for (final added in [
          ...x,
          ...y,
        ].where((line) => !base.contains(line))) {
          expect(
            out,
            contains(
              jsonEncode([
                {'insert': '$added\n'},
              ]),
            ),
            reason: reason,
          );
        }
        for (final deleted in base.where(
          (line) => !x.contains(line) || !y.contains(line),
        )) {
          expect(
            out,
            isNot(
              contains(
                jsonEncode([
                  {'insert': '$deleted\n'},
                ]),
              ),
            ),
            reason: reason,
          );
        }
        checkValid(arbitrary.body!, 'seed=$seed iteration=$iteration');
      }
    }
  });

  test('hostile inputs conflict promptly; 200,000 lines and oversized lines stay bounded', () {
    for (final bad in [
      'null',
      '{}',
      '[1]',
      '[{"delete":1}]',
      '[{"insert":4}]',
      '[{"insert":"x","attributes":4}]',
      '[{"insert":"unterminated"}]',
    ]) {
      final watch = Stopwatch()..start();
      final result = mergeBodies(
        bad,
        '[{"insert":"a\\n"}]',
        '[{"insert":"b\\n"}]',
      );
      expect(result.isConflict, isTrue, reason: 'bad=$bad');
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'bad=$bad',
      );
    }
    final hugeLine = '[{"insert":"${'z' * 250_000}\\n"}]';
    final hugeWatch = Stopwatch()..start();
    expect(mergeBodies(hugeLine, hugeLine, hugeLine).isConflict, isFalse);
    expect(hugeWatch.elapsed, lessThan(const Duration(seconds: 8)));

    final many = '${List.generate(200000, (i) => 'l$i').join('\n')}\n';
    final manyBody = jsonEncode([
      {'insert': many},
    ]);
    final watch = Stopwatch()..start();
    final result = mergeBodies(manyBody, manyBody, manyBody);
    expect(result.isConflict, isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('many separated hunks do not make merge time quadratic', () {
    const count = 1000;
    final base = List.generate(count, (i) => 'b$i');
    final left = [...base];
    final right = [...base];
    for (var i = 1; i < count; i += 4) {
      left[i] = 'l$i';
      right[i + 2] = 'r${i + 2}';
    }
    final watch = Stopwatch()..start();
    final result = mergeBodies(
      body(paragraphLines(base)),
      body(paragraphLines(left)),
      body(paragraphLines(right)),
    );
    expect(result.isConflict, isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 12)));
    expect(keys(result.body!).length, count);
  });
}
