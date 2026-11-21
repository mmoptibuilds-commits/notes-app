import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/ui/library/desktop_sidebar.dart';
import 'package:notes/ui/library/library_layout.dart';
import 'package:notes/ui/library/note_card.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/widgets/responsive.dart';

import '../../support/screenshot.dart';
import 'support.dart';

/// Masonry cards must sit where a fresh layout of the same ordered list would
/// put them, however the list got there. Inserting at the front and moving a
/// note by editing it re-orders existing children; a stale layout kept for a
/// child shows as a card in the wrong column or a gap that never closes.
void main() {
  setUpAll(loadAppFonts);

  var size = const Size(412, 915);

  Seed seedNotes(int count) {
    final s = freshServices();
    for (var i = 0; i < count; i++) {
      s.clock.ms += 1000;
      s.ids['n$i'] = s.services.notes
          .createNote(title: 'Note $i', body: _lines(i, 1 + (i * 5) % 6))
          .id;
    }
    return s;
  }

  /// Every card now built, by note id.
  Map<String, Rect> cards(WidgetTester tester) => {
    for (final e in tester.widgetList<NoteCard>(find.byType(NoteCard)))
      e.item.note.id: tester.getRect(find.byWidget(e)),
  };

  /// Where masonry puts [order] given each card's own height: every card goes
  /// to the shortest column (the first one on a tie), top to bottom.
  Map<String, Rect> expected(List<String> order, Map<String, Rect> actual) {
    final first = actual[order.first]!;
    final left = actual.values.map((r) => r.left).reduce(math.min);
    final top = actual.values.map((r) => r.top).reduce(math.min);
    final width = first.width;
    // On desktop the sidebar takes its width from the content area.
    final content = size.width >= desktopBreakpoint
        ? size.width - sidebarWidth
        : size.width;
    final cols = columnCount(content - 2 * pagePadding(content));
    final offsets = List<double>.filled(cols, 0);
    final out = <String, Rect>{};
    for (final id in order) {
      final height = actual[id]!.height;
      var c = 0;
      for (var i = 1; i < cols; i++) {
        if (offsets[i] < offsets[c] - 0.01) c = i;
      }
      out[id] = Rect.fromLTWH(
        left + c * (width + cardGap),
        top + offsets[c],
        width,
        height,
      );
      offsets[c] += height + cardGap;
    }
    return out;
  }

  /// Fails with the note's position in the list, never its text.
  void expectLaidOut(WidgetTester tester, Seed s, String step) {
    expect(tester.takeException(), isNull, reason: step);
    final repo = s.services.notes;
    final order = [for (final n in repo.listNotes()) n.id];
    final actual = cards(tester);
    expect(actual.length, order.length, reason: '$step: every note is shown');
    final want = expected(order, actual);
    for (var i = 0; i < order.length; i++) {
      final a = actual[order[i]]!;
      final w = want[order[i]]!;
      expect(
        (a.left - w.left).abs() < 0.5 && (a.top - w.top).abs() < 0.5,
        isTrue,
        reason: '$step: card #$i is at ${a.topLeft}, expected ${w.topLeft}',
      );
    }
    // Identity: each card shows its own note.
    for (final c in tester.widgetList<NoteCard>(find.byType(NoteCard))) {
      expect(c.item.note.title, repo.getNote(c.item.note.id)!.title);
    }
  }

  void edit(Seed s, String key, String body) {
    final repo = s.services.notes;
    final n = repo.getNote(s.ids[key]!)!;
    s.clock.ms += 1000;
    repo.saveContent(n.id, title: n.title, body: body, base: n.contentVv);
  }

  void insert(Seed s, String key, int lines) {
    s.clock.ms += 1000;
    s.ids[key] = s.services.notes
        .createNote(title: 'Title $key', body: _lines(99, lines))
        .id;
  }

  testWidgets('control: a fresh masonry layout matches the model', (
    tester,
  ) async {
    final s = seedNotes(7);
    addTearDown(s.services.close);
    s.services.settings.layout = LibraryLayout.masonry;
    await pumpLibrary(tester, s, size: size);
    await tester.pumpAndSettle();
    expectLaidOut(tester, s, 'fresh');
  });

  for (final width in [412.0, 900.0]) {
    testWidgets('insertions and moves keep every card where a fresh layout '
        'puts it at ${width.toInt()}px', (tester) async {
      size = Size(width, 915);
      final s = seedNotes(6);
      addTearDown(s.services.close);
      s.services.settings.layout = LibraryLayout.masonry;
      await pumpLibrary(tester, s, size: size);
      await tester.pumpAndSettle();
      expectLaidOut(tester, s, 'start');

      final steps = <(String, void Function())>[
        ('insert at the front', () => insert(s, 'a', 4)),
        ('edit the oldest note', () => edit(s, 'n0', _lines(0, 2))),
        ('insert again', () => insert(s, 'b', 1)),
        ('edit a middle note', () => edit(s, 'n3', _lines(3, 6))),
        (
          'two insertions at once',
          () {
            insert(s, 'c', 5);
            insert(s, 'd', 2);
          },
        ),
        ('edit the last note', () => edit(s, 'n1', _lines(1, 3))),
        ('another insertion', () => insert(s, 'e', 3)),
        ('edit the front note', () => edit(s, 'e', _lines(5, 6))),
      ];
      for (final (name, act) in steps) {
        act();
        await tester.pumpAndSettle();
        expectLaidOut(tester, s, name);
      }

      // Same ordered notes laid out from scratch, same window and settings.
      final incremental = cards(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpLibrary(tester, s, size: size);
      await tester.pumpAndSettle();
      final fresh = cards(tester);
      expect(fresh.keys.toSet(), incremental.keys.toSet());
      for (final id in fresh.keys) {
        expect(
          (fresh[id]!.topLeft - incremental[id]!.topLeft).distance < 0.5,
          isTrue,
          reason: 'a card differs from the fresh layout',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}

String _lines(int seed, int count) =>
    paragraphs([for (var i = 0; i < count; i++) 'Line ${i + 1} of note $seed']);
