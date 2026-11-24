import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/doc/checklist_projection.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/doc/line_merge.dart';

String textBody(List<String> lines) => jsonEncode([
  {'insert': '${lines.join('\n')}\n'},
]);

void main() {
  group('mergeBodies', () {
    test('combines edits to different paragraphs and adjacent lines', () {
      final base = textBody(['one', 'two', 'three']);
      final local = textBody(['ONE', 'two', 'THREE']);
      final remote = textBody(['one', 'TWO', 'three']);
      expect(
        mergeBodies(base, local, remote).body,
        textBody(['ONE', 'TWO', 'THREE']),
      );
    });

    test(
      'conflicts on same paragraph, insertion position and delete vs edit',
      () {
        final base = textBody(['one', 'two']);
        expect(
          mergeBodies(
            base,
            textBody(['local', 'two']),
            textBody(['remote', 'two']),
          ).isConflict,
          isTrue,
        );
        expect(
          mergeBodies(
            textBody(['one']),
            textBody(['a', 'one']),
            textBody(['b', 'one']),
          ).isConflict,
          isTrue,
        );
        expect(
          mergeBodies(
            base,
            textBody(['two']),
            textBody(['edited', 'two']),
          ).isConflict,
          isTrue,
        );
      },
    );

    test('merges a change to an image line and preserves unknown embeds', () {
      const base =
          '[{"insert":"before\\n"},{"insert":{"custom":{"x":1}}},{"insert":" after\\n"}]';
      const local =
          '[{"insert":"before\\n"},{"insert":{"custom":{"x":1}}},{"insert":" changed\\n"}]';
      const remote =
          '[{"insert":"BEFORE\\n"},{"insert":{"custom":{"x":1}}},{"insert":" after\\n"}]';
      final merged = mergeBodies(base, local, remote);
      expect(merged.isConflict, isFalse);
      expect(merged.body, contains('"custom":{"x":1}'));
      expect(mergeBodies(base, local, base).body, local);
    });

    test('a changed image embed remains an indivisible line', () {
      const base =
          '[{"insert":"caption "},{"insert":{"image":"fake://old"}},{"insert":"\\n"},{"insert":"tail\\n"}]';
      const changed =
          '[{"insert":"caption "},{"insert":{"image":"fake://new"}},{"insert":"\\n"},{"insert":"tail\\n"}]';
      final changedResult = mergeBodies(base, changed, base);
      expect(changedResult.isConflict, isFalse);
      expect(changedResult.body, contains('fake://new'));
      expect(digestBody(changedResult.body!).plainText, 'caption \ntail');
      expect(
        mergeBodies(
          base,
          changed,
          '[{"insert":"caption "},{"insert":{"image":"fake://other"}},{"insert":"\\n"},{"insert":"tail\\n"}]',
        ).isConflict,
        isTrue,
      );
    });

    test('empty body, lists, checklist and heading lines retain attributes', () {
      expect(
        mergeBodies(emptyBodyJson, emptyBodyJson, emptyBodyJson).body,
        emptyBodyJson,
      );
      const base =
          '[{"insert":"todo"},{"insert":"\\n","attributes":{"list":"unchecked"}},{"insert":"heading"},{"insert":"\\n","attributes":{"header":2}},{"insert":"last\\n"}]';
      const local =
          '[{"insert":"todo"},{"insert":"\\n","attributes":{"list":"unchecked"}},{"insert":"HEADING"},{"insert":"\\n","attributes":{"header":2}},{"insert":"last\\n"}]';
      const remote =
          '[{"insert":"todo"},{"insert":"\\n","attributes":{"list":"checked"}},{"insert":"heading"},{"insert":"\\n","attributes":{"header":2}},{"insert":"last\\n"}]';
      final result = mergeBodies(base, local, remote);
      expect(result.isConflict, isFalse);
      expect(result.body, contains('"list":"checked"'));
      expect(result.body, contains('"header":2'));
      final canonical = deltaFromBody(result.body!);
      final split = ChecklistProjection.split(canonical);
      expect(
        split.projection.merge(split.visible).toJson(),
        canonical.toJson(),
      );
    });

    test('malformed input and non newline terminated documents conflict', () {
      expect(
        mergeBodies('bad', textBody(['a']), textBody(['b'])).isConflict,
        isTrue,
      );
      expect(
        mergeBodies(
          '[{"insert":"a"}]',
          textBody(['a']),
          textBody(['a']),
        ).isConflict,
        isTrue,
      );
    });

    test('bounded diff guard reports conflict', () {
      final base = textBody(List.generate(1010, (i) => 'b$i'));
      final left = textBody(List.generate(1010, (i) => 'l$i'));
      final right = textBody(List.generate(1010, (i) => 'r$i'));
      expect(mergeBodies(base, left, right).isConflict, isTrue);
    });

    test(
      'seeded disjoint paragraph edits are preserved symmetrically and valid',
      () {
        final random = Random(910247);
        for (var iteration = 0; iteration < 150; iteration++) {
          final count = 3 + random.nextInt(12);
          final baseLines = List.generate(count, (i) => 'p$i');
          final aAt = random.nextInt(count);
          var bAt = random.nextInt(count - 1);
          if (bAt >= aAt) bAt++;
          final aLines = [...baseLines]..[aAt] = 'a$aAt';
          final bLines = [...baseLines]..[bAt] = 'b$bAt';
          final expected = [...baseLines]
            ..[aAt] = 'a$aAt'
            ..[bAt] = 'b$bAt';
          final merged = mergeBodies(
            textBody(baseLines),
            textBody(aLines),
            textBody(bLines),
          );
          final reversed = mergeBodies(
            textBody(baseLines),
            textBody(bLines),
            textBody(aLines),
          );
          expect(merged.isConflict, isFalse, reason: 'iteration $iteration');
          expect(merged.body, reversed.body);
          expect(digestBody(merged.body!).plainText, expected.join('\n'));
          final delta = deltaFromBody(merged.body!);
          expect(
            delta.toList().map((op) => op.data).whereType<String>().join(),
            endsWith('\n'),
          );
          final projected = ChecklistProjection.split(delta);
          expect(
            projected.projection.merge(projected.visible).toJson(),
            delta.toJson(),
          );
        }
      },
    );

    test('identical changes and base-side identity properties', () {
      final base = textBody(['one', 'two']);
      final changed = textBody(['ONE', 'two']);
      expect(mergeBodies(base, changed, changed).body, changed);
      expect(mergeBodies(base, base, changed).body, changed);
      expect(mergeBodies(base, changed, base).body, changed);
    });
  });
}
