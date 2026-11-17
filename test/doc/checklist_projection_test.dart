import 'dart:convert';
import 'dart:math';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/doc/checklist_projection.dart';

Delta doc(List<(String text, Map<String, dynamic>? block)> lines) {
  final d = Delta();
  for (final (text, block) in lines) {
    if (text.isNotEmpty) d.insert(text);
    d.insert('\n', block);
  }
  return d;
}

const checked = {'list': 'checked'};
const unchecked = {'list': 'unchecked'};

String show(Delta d) => jsonEncode(d.toJson());

/// Random document: plain lines, headings, tasks (some checked, some with
/// inline formatting, embeds and indent), empty lines.
Delta randomDoc(Random r, {int maxLines = 12}) {
  final d = Delta();
  final n = 1 + r.nextInt(maxLines);
  for (var i = 0; i < n; i++) {
    final words = r.nextInt(4);
    for (var w = 0; w < words; w++) {
      final text = 'w${r.nextInt(50)}${w < words - 1 ? ' ' : ''}';
      switch (r.nextInt(5)) {
        case 0:
          d.insert(text, {'bold': true});
        case 1:
          d.insert(text, {'strike': true});
        case 2:
          d.insert(text, {'link': 'https://example.org/$w'});
        default:
          d.insert(text);
      }
    }
    if (r.nextInt(12) == 0) d.insert({'image': 'att:${'a' * 64}'});
    final block = switch (r.nextInt(8)) {
      0 || 1 => {'list': 'checked'},
      2 => {'list': 'checked', 'indent': 1},
      3 || 4 => {'list': 'unchecked'},
      5 => {'header': 2},
      _ => null,
    };
    d.insert('\n', block);
  }
  return d;
}

/// A random user edit of [d] that keeps it a valid document.
Delta randomEdit(Random r, Delta d) {
  final len = documentLength(d);
  final change = Delta();
  switch (r.nextInt(3)) {
    case 0: // type text
      final at = r.nextInt(len);
      if (at > 0) change.retain(at);
      change.insert(r.nextBool() ? 'zz' : 'q\n');
    case 1: // delete a range, never the final newline
      if (len < 3) {
        change.insert('k');
        break;
      }
      final at = r.nextInt(len - 2);
      final n = 1 + r.nextInt(min(6, len - 1 - at));
      if (at > 0) change.retain(at);
      change.delete(n);
    default: // new line at the very start or just before the end
      final at = r.nextBool() ? 0 : len - 1;
      if (at > 0) change.retain(at);
      change.insert('n\n');
  }
  return change;
}

List<String> completedShown(ChecklistProjection p) => [
  for (final c in p.completed) show(c.delta),
];

void main() {
  test(
    'split removes checked lines from view and merge restores the document',
    () {
      final d = doc([
        ('Shopping', {'header': 1}),
        ('milk', unchecked),
        ('eggs', checked),
        ('note', null),
        ('bread', checked),
        ('tea', unchecked),
      ]);
      final s = ChecklistProjection.split(d);
      expect(
        show(s.visible),
        show(
          doc([
            ('Shopping', {'header': 1}),
            ('milk', unchecked),
            ('note', null),
            ('tea', unchecked),
          ]),
        ),
      );
      expect(s.projection.completed.map((c) => c.text), ['eggs', 'bread']);
      expect(show(s.projection.merge(s.visible)), show(d));
    },
  );

  test('a document with nothing checked is passed through untouched', () {
    final d = doc([('a', null), ('b', unchecked)]);
    final s = ChecklistProjection.split(d);
    expect(show(s.visible), show(d));
    expect(s.projection.isEmpty, isTrue);
    expect(show(s.projection.merge(s.visible)), show(d));
  });

  test('every line checked: view is one empty line and merge adds nothing', () {
    final d = doc([('a', checked), ('b', checked)]);
    final s = ChecklistProjection.split(d);
    expect(show(s.visible), '[{"insert":"\\n"}]');
    expect(show(s.projection.merge(s.visible)), show(d));
    // Once the user types there, the line is real and is kept.
    final typed = Delta()..insert('hello');
    s.projection.transformBy(typed);
    final visible = s.visible.compose(typed);
    expect(
      show(s.projection.merge(visible)),
      show(doc([('a', checked), ('b', checked), ('hello', null)])),
    );
  });

  test('formatting, embeds and unknown attributes of completed lines survive exactly', () {
    final d = Delta()
      ..insert('keep ')
      ..insert('bold', {'bold': true, 'color': '#ff0000'})
      ..insert({'image': 'att:abc'})
      ..insert('struck', {'strike': true})
      ..insert('\n', {'list': 'checked', 'indent': 2, 'x-custom': 'y'})
      ..insert('tail\n');
    final s = ChecklistProjection.split(d);
    expect(show(s.projection.merge(s.visible)), show(d));
    expect(
      show(s.projection.completed.single.delta),
      show(d.slice(0, documentLength(d) - 5)),
    );
  });

  test('property: merge(split(d)) == d for random documents', () {
    final r = Random(20261117);
    for (var i = 0; i < 2000; i++) {
      final d = randomDoc(r);
      final s = ChecklistProjection.split(d);
      expect(
        show(s.projection.merge(s.visible)),
        show(d),
        reason: 'case $i: ${show(d)}',
      );
    }
  });

  test('property: after random edits, completed lines are intact, in order, and the view is unchanged', () {
    final r = Random(7);
    for (var i = 0; i < 1500; i++) {
      final d = randomDoc(r);
      final s = ChecklistProjection.split(d);
      final p = s.projection;
      final before = completedShown(p);
      var visible = s.visible;
      for (var e = 0; e < 1 + r.nextInt(6); e++) {
        final change = randomEdit(r, visible);
        visible = visible.compose(change);
        p.transformBy(change);
      }
      final merged = p.merge(visible);
      final again = ChecklistProjection.split(merged);
      expect(completedShown(again.projection), before, reason: 'case $i');
      // Holds even when the view is a single empty line: split recreates it.
      expect(show(again.visible), show(visible), reason: 'case $i');
    }
  });

  test('typing at the start of the line after a completed item keeps the item above it', () {
    final d = doc([('x', null), ('done', checked), ('y', null)]);
    final s = ChecklistProjection.split(d);
    final change = Delta()
      ..retain(2)
      ..insert('z');
    s.projection.transformBy(change);
    final merged = s.projection.merge(s.visible.compose(change));
    expect(
      show(merged),
      show(doc([('x', null), ('done', checked), ('zy', null)])),
    );
  });

  test('extractChecked moves a newly checked line and keeps document order with existing ones', () {
    // Stored: a, [x]one, b, c, [x]two, d   -> view: a, b, c, d
    final d = doc([
      ('a', unchecked),
      ('one', checked),
      ('b', unchecked),
      ('c', unchecked),
      ('two', checked),
      ('d', unchecked),
    ]);
    final s = ChecklistProjection.split(d);
    final p = s.projection;
    // The user checks "b" (offset 2..4 in the view) and "c".
    var visible = s.visible;
    final tick = Delta()
      ..retain(3)
      ..retain(1, checked)
      ..retain(1)
      ..retain(1, checked);
    visible = visible.compose(tick);
    p.transformBy(tick);
    expect(ChecklistProjection.mayCheck(tick), isTrue);
    final change = p.extractChecked(visible)!;
    visible = visible.compose(change);
    expect(show(visible), show(doc([('a', unchecked), ('d', unchecked)])));
    expect(p.completed.map((c) => c.text), ['one', 'b', 'c', 'two']);
    expect(
      show(p.merge(visible)),
      show(
        doc([
          ('a', unchecked),
          ('one', checked),
          ('b', checked),
          ('c', checked),
          ('two', checked),
          ('d', unchecked),
        ]),
      ),
    );
    expect(p.extractChecked(visible), isNull);
    expect(
      ChecklistProjection.mayCheck(
        Delta()
          ..retain(1)
          ..insert('x'),
      ),
      isFalse,
    );
  });

  test(
    'checking the only line leaves an empty line and stores just the item',
    () {
      var visible = doc([('solo', checked)]);
      final p = ChecklistProjection.split(doc([('', null)])).projection;
      final change = p.extractChecked(visible)!;
      visible = visible.compose(change);
      expect(show(visible), '[{"insert":"\\n"}]');
      expect(show(p.merge(visible)), show(doc([('solo', checked)])));
    },
  );

  test('checking the last line of several removes it cleanly', () {
    var visible = doc([('a', null), ('b', checked)]);
    final p = ChecklistProjection.split(doc([('', null)])).projection;
    visible = visible.compose(p.extractChecked(visible)!);
    expect(show(visible), show(doc([('a', null)])));
    expect(show(p.merge(visible)), show(doc([('a', null), ('b', checked)])));
  });

  test('restore puts the line back at its own place as unchecked', () {
    final d = doc([
      ('a', unchecked),
      ('one', checked),
      ('b', unchecked),
      ('two', checked),
    ]);
    final s = ChecklistProjection.split(d);
    final p = s.projection;
    var visible = s.visible;
    final two = p.completed[1].id;
    visible = visible.compose(p.restore([two], visible)!);
    expect(
      show(visible),
      show(doc([('a', unchecked), ('b', unchecked), ('two', unchecked)])),
    );
    visible = visible.compose(p.restore([p.completed.single.id], visible)!);
    expect(
      show(visible),
      show(
        doc([
          ('a', unchecked),
          ('one', unchecked),
          ('b', unchecked),
          ('two', unchecked),
        ]),
      ),
    );
    expect(p.isEmpty, isTrue);
    expect(p.restore([99], visible), isNull);
  });

  test('restore all at once equals restoring one by one', () {
    final r = Random(99);
    for (var i = 0; i < 500; i++) {
      final d = randomDoc(r);
      final a = ChecklistProjection.split(d);
      final b = ChecklistProjection.split(d);
      if (a.projection.isEmpty) continue;
      final all = a.projection.restore(
        a.projection.completed.map((c) => c.id),
        a.visible,
      )!;
      final atOnce = a.visible.compose(all);
      var stepwise = b.visible;
      while (!b.projection.isEmpty) {
        // Restore in a random order.
        final pick =
            b.projection.completed[r.nextInt(b.projection.completed.length)].id;
        stepwise = stepwise.compose(b.projection.restore([pick], stepwise)!);
      }
      expect(show(stepwise), show(atOnce), reason: 'case $i: ${show(d)}');
      // Nothing checked remains and every line of the original is present.
      expect(ChecklistProjection.split(atOnce).projection.isEmpty, isTrue);
      expect(documentLength(atOnce), documentLength(d));
    }
  });

  test('restore removes a whole-line legacy strike-through but keeps partial strikes', () {
    final d = Delta()
      ..insert('all struck', {'strike': true})
      ..insert('\n', checked)
      ..insert('partly ')
      ..insert('struck', {'strike': true, 'bold': true})
      ..insert('\n', checked);
    final s = ChecklistProjection.split(d);
    final visible = s.visible.compose(
      s.projection.restore(s.projection.completed.map((c) => c.id), s.visible)!,
    );
    final expected = Delta()
      ..insert('all struck')
      ..insert('\n', unchecked)
      ..insert('partly ')
      ..insert('struck', {'strike': true, 'bold': true})
      ..insert('\n', unchecked);
    expect(show(visible), show(expected));
  });

  test('remove deletes for good; putBack undoes it in place', () {
    final d = doc([
      ('a', null),
      ('one', checked),
      ('b', null),
      ('two', checked),
      ('three', checked),
    ]);
    final s = ChecklistProjection.split(d);
    final p = s.projection;
    final gone = p.remove([p.completed[0].id, p.completed[2].id]);
    expect(
      show(p.merge(s.visible)),
      show(doc([('a', null), ('b', null), ('two', checked)])),
    );
    p.putBack(gone);
    expect(show(p.merge(s.visible)), show(d));
  });

  test('deleting text around a completed item never drops or splits it', () {
    final d = doc([('alpha', null), ('done', checked), ('beta', null)]);
    final s = ChecklistProjection.split(d);
    // Delete from the middle of "alpha" to the middle of "beta": "al" + "ta".
    final change = Delta()
      ..retain(2)
      ..delete(6);
    s.projection.transformBy(change);
    final visible = s.visible.compose(change);
    final merged = s.projection.merge(visible);
    expect(show(merged), show(doc([('alta', null), ('done', checked)])));
  });

  test('body JSON helpers', () {
    final d = doc([('a', checked)]);
    expect(show(deltaFromBody(bodyFromDelta(d))), show(d));
    expect(
      show(deltaFromBody('{"ops":[{"insert":"x\\n"}]}')),
      '[{"insert":"x\\n"}]',
    );
    expect(() => deltaFromBody('"x"'), throwsFormatException);
  });
}
