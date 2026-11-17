import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/doc/delta_text.dart';

String body(List<Object> ops) => jsonEncode(ops);

void main() {
  test('lines carry the attributes of their newline', () {
    final lines = linesOf(
      decodeOps(
        body([
          {'insert': 'Title'},
          {
            'insert': '\n',
            'attributes': {'header': 1},
          },
          {'insert': 'plain\nmilk'},
          {
            'insert': '\n',
            'attributes': {'list': 'unchecked'},
          },
          {'insert': 'eggs'},
          {
            'insert': '\n',
            'attributes': {'list': 'checked'},
          },
        ]),
      ),
    );
    expect(lines.map((l) => l.text), ['Title', 'plain', 'milk', 'eggs']);
    expect(lines[0].attributes, {'header': 1});
    expect(lines[1].attributes, isEmpty);
    expect(lines[2].isUnchecked, isTrue);
    expect(lines[3].isChecked, isTrue);
  });

  test(
    'digest: search text keeps everything, preview hides completed tasks',
    () {
      final d = digestBody(
        body([
          {'insert': 'Shopping\n\n'},
          {'insert': 'milk'},
          {
            'insert': '\n',
            'attributes': {'list': 'unchecked'},
          },
          {'insert': 'eggs'},
          {
            'insert': '\n',
            'attributes': {'list': 'checked'},
          },
          {'insert': 'one'},
          {
            'insert': '\n',
            'attributes': {'list': 'ordered'},
          },
          {'insert': 'two'},
          {
            'insert': '\n',
            'attributes': {'list': 'ordered'},
          },
          {'insert': 'dot'},
          {
            'insert': '\n',
            'attributes': {'list': 'bullet'},
          },
        ]),
      );
      expect(d.plainText, 'Shopping\n\nmilk\neggs\none\ntwo\ndot');
      expect(d.preview, 'Shopping\n☐ milk\n1. one\n2. two\n• dot');
      expect(d.tasksTotal, 2);
      expect(d.tasksDone, 1);
      expect(d.isBlank, isFalse);
    },
  );

  test('images are collected and an image-only note is not blank', () {
    final d = digestBody(
      body([
        {
          'insert': {'image': 'att:abc'},
        },
        {'insert': '\n'},
      ]),
    );
    expect(d.imageSources, ['att:abc']);
    expect(d.plainText, '');
    expect(d.isBlank, isFalse);
    expect(digestBody(emptyBodyJson).isBlank, isTrue);
  });

  test('preview is bounded and never splits a surrogate pair', () {
    final d = digestBody(
      body([
        {'insert': '${'😀' * 400}\n'},
      ]),
      previewChars: 11,
    );
    expect(d.preview.endsWith('…'), isTrue);
    expect(d.preview.runes.where((r) => r == 0xFFFD), isEmpty);
    expect(() => utf8.encode(d.preview), returnsNormally);
    expect(d.preview.length, lessThanOrEqualTo(12));
  });

  test('accepts {"ops": [...]} and rejects non-deltas', () {
    expect(digestBody('{"ops":[{"insert":"hi\\n"}]}').plainText, 'hi');
    expect(() => digestBody('"just a string"'), throwsFormatException);
    expect(() => digestBody('not json'), throwsFormatException);
    expect(() => digestBody('[1,2]'), throwsFormatException);
  });

  test('plain text becomes a one-op body', () {
    expect(digestBody(bodyFromPlainText('a\r\nb')).plainText, 'a\nb');
  });
}
