import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/doc/markdown.dart';

String body(List<Object> ops) => jsonEncode(ops);
Map<String, Object> nl([Map<String, Object>? attrs]) => {
  'insert': '\n',
  'attributes': ?attrs,
};
Map<String, Object> t(String text, [Map<String, Object>? attrs]) => {
  'insert': text,
  'attributes': ?attrs,
};

void main() {
  group('deltaToMarkdown', () {
    void md(List<Object> ops, String expected) =>
        expect(deltaToMarkdown(body(ops)), expected);

    test('plain paragraphs are separated by a blank line', () {
      md([t('one'), nl(), t('two'), nl()], 'one\n\ntwo\n');
    });
    test('empty document and empty paragraphs', () {
      md([nl()], '');
      md([t('a'), nl(), nl(), t('b'), nl()], 'a\n\nb\n');
    });
    test('headings 1-3', () {
      md([
        t('A'),
        nl({'header': 1}),
        t('B'),
        nl({'header': 2}),
        t('C'),
        nl({'header': 3}),
      ], '# A\n\n## B\n\n### C\n');
    });
    test('inline styles', () {
      md([
        t('b', {'bold': true}),
        nl(),
      ], '**b**\n');
      md([
        t('i', {'italic': true}),
        nl(),
      ], '*i*\n');
      md([
        t('s', {'strike': true}),
        nl(),
      ], '~~s~~\n');
      md([
        t('c', {'code': true}),
        nl(),
      ], '`c`\n');
      md([
        t('l', {'link': 'https://e.x/a'}),
        nl(),
      ], '[l](https://e.x/a)\n');
      md([
        t('bi', {'bold': true, 'italic': true}),
        nl(),
      ], '***bi***\n');
    });
    test('styles mixed in a line, shared marks stay open', () {
      md([
        t('a '),
        t('bold', {'bold': true}),
        t(' bi', {'bold': true, 'italic': true}),
        t(' end'),
        nl(),
      ], 'a **bold *bi*** end\n');
    });
    test('whitespace stays outside the markers', () {
      md([
        t('x'),
        t(' pad ', {'bold': true}),
        t('y'),
        nl(),
      ], 'x **pad** y\n');
    });
    test('inline code with backticks', () {
      md([
        t('a`b', {'code': true}),
        nl(),
      ], '``a`b``\n');
    });
    test('bullet and numbered lists with indent levels', () {
      md([
        t('a'),
        nl({'list': 'bullet'}),
        t('b'),
        nl({'list': 'bullet', 'indent': 1}),
        t('c'),
        nl({'list': 'bullet', 'indent': 2}),
        t('d'),
        nl({'list': 'bullet'}),
      ], '- a\n    - b\n        - c\n- d\n');
      md([
        t('x'),
        nl({'list': 'ordered'}),
        t('y'),
        nl({'list': 'ordered'}),
        t('y1'),
        nl({'list': 'ordered', 'indent': 1}),
        t('y2'),
        nl({'list': 'ordered', 'indent': 1}),
        t('z'),
        nl({'list': 'ordered'}),
      ], '1. x\n2. y\n    1. y1\n    2. y2\n3. z\n');
    });
    test('a list is separated from the paragraph after it', () {
      md([
        t('a'),
        nl({'list': 'bullet'}),
        t('p'),
        nl(),
      ], '- a\n\np\n');
    });
    test('checklists', () {
      md([
        t('todo'),
        nl({'list': 'unchecked'}),
        t('done', {'strike': true}),
        nl({'list': 'checked'}),
      ], '- [ ] todo\n- [x] ~~done~~\n');
    });
    test('block quotes', () {
      md([
        t('q1'),
        nl({'blockquote': true}),
        t('q2'),
        nl({'blockquote': true}),
      ], '> q1\n> q2\n');
    });
    test('fenced code blocks, with and without a language', () {
      md([
        t('x = 1'),
        nl({'code-block': true}),
        t('y *2*'),
        nl({'code-block': true}),
      ], '```\nx = 1\ny *2*\n```\n');
      md([
        t('print()'),
        nl({'code-block': 'python'}),
      ], '```python\nprint()\n```\n');
      md([
        t('```'),
        nl({'code-block': true}),
      ], '````\n```\n````\n');
    });
    test('images and dividers', () {
      md([
        {
          'insert': {'image': 'att:abc'},
        },
        nl(),
      ], '![](att:abc)\n');
      md([
        t('see '),
        {
          'insert': {'image': 'https://e.x/a b.png'},
        },
        nl(),
      ], 'see ![](https://e.x/a%20b.png)\n');
      md([
        t('a'),
        nl(),
        {
          'insert': {'divider': 'hr'},
        },
        nl(),
        t('b'),
        nl(),
      ], 'a\n\n---\n\nb\n');
    });
    test('characters that need escaping', () {
      md([t('3.14 a_b - x! #1'), nl()], '3.14 a\\_b - x! #1\n');
      md([
        t(r'*star* [x] `tick` <b> ~t~ \back'),
        nl(),
      ], '\\*star\\* \\[x\\] \\`tick\\` \\<b> \\~t\\~ \\\\back\n');
      md([t('# not a heading'), nl()], '\\# not a heading\n');
      md([t('1. not a list'), nl()], '1\\. not a list\n');
      md([t('- not a bullet'), nl()], '\\- not a bullet\n');
      md([t('> not a quote'), nl()], '\\> not a quote\n');
      md([t('---'), nl()], '\\---\n');
    });
    test('unknown embeds and attributes never throw and keep text', () {
      md([
        t('before '),
        {
          'insert': {'table': '{"x":1}'},
        },
        t(' after', {'underline': true, 'color': '#f00', 'x-new': 'y'}),
        nl({'align': 'center'}),
      ], 'before \\[table\\] after\n');
    });
    test('a body without a final newline still converts', () {
      md([t('tail')], 'tail\n');
    });
    test('rejects a body that is not a Delta', () {
      expect(() => deltaToMarkdown('"x"'), throwsFormatException);
    });
  });

  group('markdownToDelta', () {
    void delta(String markdown, List<Object> expected) =>
        expect(markdownToDelta(markdown), body(expected));

    test('paragraphs, soft breaks and empty input', () {
      delta('one\n\ntwo\n', [t('one'), nl(), t('two'), nl()]);
      delta('a\nb', [t('a'), nl(), t('b'), nl()]);
      expect(markdownToDelta(''), '[{"insert":"\\n"}]');
    });
    test('headings', () {
      delta('# A\n## B\n### C', [
        t('A'),
        nl({'header': 1}),
        t('B'),
        nl({'header': 2}),
        t('C'),
        nl({'header': 3}),
      ]);
    });
    test('inline styles', () {
      delta('**b** *i* _i2_ ~~s~~ `c` [l](https://e.x)', [
        t('b', {'bold': true}),
        t(' '),
        t('i', {'italic': true}),
        t(' '),
        t('i2', {'italic': true}),
        t(' '),
        t('s', {'strike': true}),
        t(' '),
        t('c', {'code': true}),
        t(' '),
        t('l', {'link': 'https://e.x'}),
        nl(),
      ]);
      delta('***bi***', [
        t('bi', {'bold': true, 'italic': true}),
        nl(),
      ]);
    });
    test('lists with indent levels', () {
      delta('- a\n    - b\n        - c\n- d', [
        t('a'),
        nl({'list': 'bullet'}),
        t('b'),
        nl({'list': 'bullet', 'indent': 1}),
        t('c'),
        nl({'list': 'bullet', 'indent': 2}),
        t('d'),
        nl({'list': 'bullet'}),
      ]);
      delta('1. x\n2. y\n    1. z', [
        t('x'),
        nl({'list': 'ordered'}),
        t('y'),
        nl({'list': 'ordered'}),
        t('z'),
        nl({'list': 'ordered', 'indent': 1}),
      ]);
    });
    test('checklists', () {
      delta('- [ ] todo\n- [x] done', [
        t('todo'),
        nl({'list': 'unchecked'}),
        t('done'),
        nl({'list': 'checked'}),
      ]);
    });
    test('block quotes, fenced and indented code, rules, images', () {
      delta('> q1\n> q2', [
        t('q1'),
        nl({'blockquote': true}),
        t('q2'),
        nl({'blockquote': true}),
      ]);
      delta('```\nx = 1\n\ny\n```', [
        t('x = 1'),
        nl({'code-block': true}),
        nl({'code-block': true}),
        t('y'),
        nl({'code-block': true}),
      ]);
      delta('```dart\nvar a;\n```', [
        t('var a;'),
        nl({'code-block': 'dart'}),
      ]);
      delta('---', [
        {
          'insert': {'divider': 'hr'},
        },
        nl(),
      ]);
      delta('![](att:abc)', [
        {
          'insert': {'image': 'att:abc'},
        },
        nl(),
      ]);
    });
    test('escapes are removed', () {
      delta('3.14 a\\_b \\# \\*x\\*', [t('3.14 a_b # *x*'), nl()]);
    });
    test('a table keeps its text', () {
      final out = markdownToDelta('| a | b |\n|---|---|\n| 1 | 2 |\n');
      expect(out, contains('a | b'));
      expect(out, contains('1 | 2'));
    });
    test('raw html and odd input never throw', () {
      expect(markdownToDelta('<div>hi</div>\n\n<b>x</b>'), contains('hi'));
      expect(markdownToDelta('\u0000 weird \r\n text'), isNotEmpty);
    });
    test('always ends with a newline op', () {
      final ops = jsonDecode(markdownToDelta('text')) as List;
      expect((ops.last as Map)['insert'], '\n');
    });
  });

  group('round trips', () {
    final samples = <String, List<Object>>{
      'everything': [
        t('Title'),
        nl({'header': 1}),
        t('plain '),
        t('bold', {'bold': true}),
        t(' '),
        t('it', {'italic': true}),
        t(' '),
        t('gone', {'strike': true}),
        t(' '),
        t('code', {'code': true}),
        t(' '),
        t('link', {'link': 'https://example.invalid/x'}),
        nl(),
        t('a'),
        nl({'list': 'bullet'}),
        t('b'),
        nl({'list': 'bullet', 'indent': 1}),
        t('one'),
        nl({'list': 'ordered'}),
        t('two'),
        nl({'list': 'ordered'}),
        t('open'),
        nl({'list': 'unchecked'}),
        t('shut'),
        nl({'list': 'checked'}),
        t('quoted'),
        nl({'blockquote': true}),
        t('let x = 1;'),
        nl({'code-block': 'js'}),
        t('3.14 a_b - x! #1 [x] *y* <z>'),
        nl(),
        {
          'insert': {'image': 'att:0011'},
        },
        nl(),
        {
          'insert': {'divider': 'hr'},
        },
        nl(),
        t('end'),
        nl(),
      ],
      'tricky text': [
        t('1. not a list'),
        nl(),
        t('# not a heading'),
        nl(),
        t('- x'),
        nl({'list': 'bullet'}),
        t('> quoted'),
        nl({'blockquote': true}),
        t('a\\b `c`'),
        nl(),
        t('bold *and italic*', {'bold': true}),
        nl(),
      ],
    };
    samples.forEach((name, ops) {
      test('delta -> markdown -> delta -> markdown is stable: $name', () {
        final md1 = deltaToMarkdown(body(ops));
        final delta1 = markdownToDelta(md1);
        final md2 = deltaToMarkdown(delta1);
        expect(md2, md1);
        final delta2 = markdownToDelta(md2);
        expect(delta2, delta1);
      });
    });
    test('the text of every line survives the round trip', () {
      for (final ops in samples.values) {
        final back = markdownToDelta(deltaToMarkdown(body(ops)));
        final before = StringBuffer();
        for (final op in ops) {
          final ins = (op as Map)['insert'];
          if (ins is String) before.write(ins);
        }
        final after = StringBuffer();
        for (final op in jsonDecode(back) as List) {
          final ins = (op as Map)['insert'];
          if (ins is String) after.write(ins);
        }
        // Compare non-empty lines: empty paragraphs are not kept.
        List<String> lines(String s) =>
            s.split('\n').where((l) => l.trim().isNotEmpty).toList();
        expect(lines(after.toString()), lines(before.toString()));
      }
    });
    test('markdown -> delta -> markdown reaches a fixed point', () {
      const src =
          '# T\n\nhello **w** and *x*\n\n- [ ] a\n- [x] b\n\n1. n\n2. m\n\n'
          '> q\n\n```py\nx\n```\n\n---\n';
      final once = deltaToMarkdown(markdownToDelta(src));
      expect(once, src);
      expect(deltaToMarkdown(markdownToDelta(once)), once);
    });
  });
}
