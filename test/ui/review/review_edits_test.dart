import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_settings.dart';
import 'package:notes/doc/delta_text.dart';
import 'package:notes/app.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/review/review_edits_screen.dart';
import 'package:notes/ui/theme/app_theme.dart';

Future<void> pumpReview(
  WidgetTester tester,
  AppServices s,
  String id,
  Size size,
  double scale,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppScope(
      services: s,
      child: ListenableBuilder(
        listenable: s.settings,
        builder: (context, _) => MaterialApp(
          theme: buildTheme(s.settings),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: ReviewEditsScreen(noteId: id),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String textBody(String value) => bodyFromPlainText(value);

void main() {
  for (final (theme, size, scale) in <(AppTheme, Size, double)>[
    (AppTheme.amoled, const Size(360, 640), 1),
    (AppTheme.charcoal, const Size(800, 900), 1.4),
    (AppTheme.light, const Size(1024, 768), 2),
  ]) {
    testWidgets('review displays both versions ${theme.name} $scale', (
      tester,
    ) async {
      final s = AppServices.inMemory();
      addTearDown(s.close);
      s.settings.theme = theme;
      final main = s.notes.createNote(
        title: 'Plan',
        body: textBody('alpha\nshared'),
      );
      final copy = s.notes.createNote(
        id: 'copy-$scale',
        body: textBody('beta\nshared'),
      );
      s.db.transaction(
        () => s.notes.writeRecord(
          s.notes.getRecord(copy.id)!.copyWith(conflictOf: main.id),
        ),
      );
      final seqBeforeReview = s.db.currentSeq;
      await pumpReview(tester, s, main.id, size, scale);
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('Use this version'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        s.db.currentSeq,
        seqBeforeReview,
        reason: 'opening review is read-only',
      );
    });
  }

  testWidgets('use this version preserves the prior main as a copy', (
    tester,
  ) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    final main = s.notes.createNote(body: textBody('original'));
    final copy = s.notes.createNote(
      id: 'chosen-copy',
      body: textBody('chosen'),
    );
    s.db.transaction(
      () => s.notes.writeRecord(
        s.notes.getRecord(copy.id)!.copyWith(conflictOf: main.id),
      ),
    );
    await pumpReview(tester, s, main.id, const Size(412, 915), 1);
    await tester.tap(find.text('Use this version'));
    await tester.pumpAndSettle();
    expect(s.notes.getNote(main.id)!.preview, 'chosen');
    expect(s.notes.conflictCopiesOf(main.id).single.preview, 'original');
  });

  testWidgets('keep both promotes copy and dismiss requires confirmation', (
    tester,
  ) async {
    final s = AppServices.inMemory();
    addTearDown(s.close);
    final main = s.notes.createNote(body: textBody('main'));
    final copy = s.notes.createNote(
      id: 'kept-copy',
      body: textBody('alternative'),
    );
    s.db.transaction(
      () => s.notes.writeRecord(
        s.notes.getRecord(copy.id)!.copyWith(conflictOf: main.id),
      ),
    );
    await pumpReview(tester, s, main.id, const Size(412, 915), 1);
    await tester.tap(find.text('Keep both'));
    await tester.pumpAndSettle();
    expect(s.notes.getNote('kept-copy')!.conflictOf, isNull);
    expect(find.text('No edits to review.'), findsOneWidget);
    final second = s.notes.createNote(
      id: 'dismiss-copy',
      body: textBody('dismiss'),
    );
    s.db.transaction(
      () => s.notes.writeRecord(
        s.notes.getRecord(second.id)!.copyWith(conflictOf: main.id),
      ),
    );
    // Recreate the route to fetch the new copy list.
    await tester.pumpWidget(const SizedBox());
    await pumpReview(tester, s, main.id, const Size(412, 915), 1);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Dismiss this version?'), findsOneWidget);
    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();
    expect(s.notes.getNote('dismiss-copy'), isNull);
  });
}
