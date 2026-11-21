import 'package:flutter_test/flutter_test.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/importer/markdown_import.dart';
import 'package:notes/platform/bootstrap.dart';

void main() {
  test('each file becomes a note; a leading heading is the title', () {
    final s = AppServices.inMemory();
    final ids = importMarkdownFiles(s.notes, [
      (name: 'plan.md', text: '# Weekend plan\n\n- [ ] Buy milk\n- [x] Call\n'),
      (name: 'loose notes.markdown', text: 'Just **text**.\n'),
    ]);
    expect(ids, hasLength(2));
    final a = s.notes.getNote(ids[0])!;
    expect(a.title, 'Weekend plan');
    expect(digestBody(a.body).plainText, contains('Buy milk'));
    expect(a.body, contains('"list":"unchecked"'));
    final b = s.notes.getNote(ids[1])!;
    expect(b.title, 'loose notes');
    expect(digestBody(b.body).plainText, contains('Just text.'));
  });

  test('a file without a heading keeps all its text in the body', () {
    final s = AppServices.inMemory();
    final id = importMarkdownFiles(s.notes, [
      (name: 'todo.txt', text: 'First line\n## Section\nMore'),
    ]).single;
    final n = s.notes.getNote(id)!;
    expect(n.title, 'todo');
    expect(digestBody(n.body).plainText, contains('First line'));
    expect(digestBody(n.body).plainText, contains('Section'));
  });
}
