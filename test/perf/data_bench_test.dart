import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/doc/delta_text.dart';

/// Timings on synthetic data, run in the Dart VM (JIT) under `flutter test`.
/// They show orders of magnitude and catch regressions; they are NOT release
/// build figures. The assertions are deliberately loose.
void main() {
  final words = [
    'meeting',
    'budget',
    'groceries',
    'travel',
    'recipe',
    'project',
    'idea',
    'draft',
    'invoice',
    'garden',
    'router',
    'password',
    'lecture',
    'workout',
    'receipt',
    'reading',
    'plan',
    'quarterly',
    'holiday',
    'backup',
  ];
  String sentence(Random r, int n) =>
      List.generate(n, (_) => words[r.nextInt(words.length)]).join(' ');

  test('5,000 notes: write, list, search, edit', () {
    final dir = Directory.systemTemp.createTempSync('notes bench ');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = AppDatabase.open(
      '${dir.path}/b.db',
      key: List.filled(32, 7).cast<int>().let((l) => Uint8List.fromList(l)),
    );
    addTearDown(db.close);
    final repo = NoteRepository(db);
    final r = Random(1);
    final sw = Stopwatch()..start();
    db.transaction(() {
      for (var i = 0; i < 5000; i++) {
        final lines = [
          for (var l = 0; l < 12; l++) {'insert': '${sentence(r, 12)}\n'},
        ];
        repo.createNote(title: sentence(r, 3), body: jsonEncode(lines));
      }
    });
    final insert = sw.elapsedMilliseconds;
    sw
      ..reset()
      ..start();
    final listed = repo.listNotes();
    final list = sw.elapsedMilliseconds;
    var worst = 0;
    final queries = [
      'budget',
      'budget travel',
      'quart',
      'zzzz',
      'recipe garden router',
    ];
    for (final q in queries) {
      sw
        ..reset()
        ..start();
      final hits = repo.search(q);
      final ms = sw.elapsedMicroseconds / 1000;
      if (ms > worst) worst = ms.ceil();
      // ignore: avoid_print
      print('search "$q": ${hits.length} hits in ${ms.toStringAsFixed(1)} ms');
    }
    final counts = (() {
      sw
        ..reset()
        ..start();
      repo.counts();
      return sw.elapsedMicroseconds / 1000;
    })();
    final id = listed[2500].id;
    final note = repo.getNote(id)!;
    sw
      ..reset()
      ..start();
    var base = note.contentVv;
    for (var i = 0; i < 50; i++) {
      final res = repo.saveContent(
        id,
        title: note.title,
        body: jsonEncode([
          {'insert': 'edit $i ${sentence(r, 12)}\n'},
        ]),
        base: base,
      );
      base = res.contentVv;
    }
    final save = sw.elapsedMicroseconds / 50 / 1000;
    // ignore: avoid_print
    print(
      'create 5000 notes: $insert ms | list all: $list ms | counts: ${counts.toStringAsFixed(1)} ms | avg save of a small note: ${save.toStringAsFixed(2)} ms',
    );
    expect(listed.length, 5000);
    expect(worst, lessThan(250));
    expect(save, lessThan(50));
  });

  test('a 1 MB note: digest, save and search stay quick enough to type in', () {
    final db = AppDatabase.open(null);
    addTearDown(db.close);
    final repo = NoteRepository(db);
    final r = Random(2);
    final big = jsonEncode([
      for (var l = 0; l < 8000; l++) {'insert': '${sentence(r, 18)}\n'},
    ]);
    // ignore: avoid_print
    print('body size: ${(big.length / 1024).round()} KiB');
    final sw = Stopwatch()..start();
    final n = repo.createNote(title: 'big', body: big);
    final create = sw.elapsedMilliseconds;
    sw
      ..reset()
      ..start();
    digestBody(big);
    final digest = sw.elapsedMilliseconds;
    sw
      ..reset()
      ..start();
    final edited = big.replaceFirst('"insert":"', '"insert":"x');
    repo.saveContent(n.id, title: 'big', body: edited, base: n.contentVv);
    final save = sw.elapsedMilliseconds;
    sw
      ..reset()
      ..start();
    final hits = repo.search('quarterly holiday');
    final search = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print(
      '1 MB note: create $create ms, digest $digest ms, save $save ms, search $search ms (${hits.length} hits)',
    );
    expect(save, lessThan(1500));
    expect(search, lessThan(300));
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
