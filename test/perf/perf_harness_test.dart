import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' show Document;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';

import '../../tool/perf/seed_library.dart' show syntheticLargeBody;

void main() {
  test('500 synthetic notes list and search within generous bounds', () {
    final db = AppDatabase.open(null);
    addTearDown(db.close);
    final repo = NoteRepository(db);
    db.transaction(() {
      for (var i = 0; i < 500; i++) {
        repo.createNote(
          title: 'Benchmark note $i',
          body: jsonEncode([
            {'insert': 'quarterly plan item $i with meeting budget details\n'},
            {
              'insert': 'checklist line\n',
              'attributes': {'list': i.isEven ? 'checked' : 'unchecked'},
            },
          ]),
        );
      }
    });

    final listTimer = Stopwatch()..start();
    final listed = repo.listNotes();
    listTimer.stop();
    final searchTimer = Stopwatch()..start();
    final hits = repo.search('quarterly budget', limit: 500);
    searchTimer.stop();

    // These are regression ceilings in a JIT test VM, not release targets.
    expect(listed, hasLength(500));
    expect(hits, hasLength(500));
    expect(listTimer.elapsedMilliseconds, lessThan(5000));
    expect(searchTimer.elapsedMilliseconds, lessThan(5000));
    // ignore: avoid_print
    print(
      '500-note JIT: list ${listTimer.elapsedMilliseconds} ms; '
      'search ${searchTimer.elapsedMilliseconds} ms',
    );
  });

  test('approximately 200 KB rich Delta loads as a Quill Document', () {
    final body = syntheticLargeBody();
    final bytes = utf8.encode(body).length;
    expect(bytes, greaterThan(170 * 1024));
    expect(bytes, lessThan(230 * 1024));
    final ops = (jsonDecode(body) as List).cast<Map<String, dynamic>>();

    final timer = Stopwatch()..start();
    final document = Document.fromJson(ops);
    timer.stop();

    expect(document.toPlainText(), isNotEmpty);
    expect(timer.elapsedMilliseconds, lessThan(5000));
    // ignore: avoid_print
    print(
      'Quill Document.fromJson ${bytes ~/ 1024} KiB: '
      '${timer.elapsedMilliseconds} ms (JIT)',
    );
  });
}
