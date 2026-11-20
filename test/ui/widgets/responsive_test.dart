import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ui/material.dart';
import 'package:notes/ui/widgets/responsive.dart';

void main() {
  group('pageGutter', () {
    test('keeps the minimum gutter on narrow windows', () {
      for (final w in [320.0, 360.0, 480.0, 640.0]) {
        expect(pageGutter(w), pageMinGutter, reason: '$w');
      }
    });

    test('centres a pageMaxWidth column on wide windows', () {
      expect(pageGutter(1440), (1440 - pageMaxWidth) / 2);
      // Exactly one column wide: the gutter is the whole leftover space.
      expect(pageGutter(pageMaxWidth + 24), 12);
    });

    test('never drops below the minimum gutter at any width', () {
      for (var w = 200.0; w <= 2000; w += 37) {
        expect(pageGutter(w), greaterThanOrEqualTo(pageMinGutter));
        // The column never exceeds its maximum width.
        expect(w - 2 * pageGutter(w), lessThanOrEqualTo(pageMaxWidth));
      }
    });
  });

  group('columnsFor', () {
    test('one column for an empty or tiny area', () {
      expect(columnsFor(0, minItemWidth: 200, maxItemWidth: 280), 1);
      expect(columnsFor(150, minItemWidth: 200, maxItemWidth: 280), 1);
    });

    test('fills the width with items of at least the minimum', () {
      // 1000 px, items >= 200 px with 8 px gaps: 4 columns of 242 px.
      expect(columnsFor(1000, minItemWidth: 200, maxItemWidth: 280), 4);
    });

    test('with more than one column, no item exceeds the maximum', () {
      for (var w = 100.0; w <= 2400; w += 13) {
        final cols = columnsFor(w, minItemWidth: 200, maxItemWidth: 280);
        expect(cols, greaterThanOrEqualTo(1));
        if (cols > 1) {
          final item = (w - (cols - 1) * 8) / cols;
          expect(item, lessThanOrEqualTo(280 + 1e-9), reason: 'w=$w');
        }
      }
    });

    test('items reach the minimum width whenever a column count allows it', () {
      // 1000 px: 4 items of 242 px. 600 px: 2 items of 296 px exceed the
      // maximum, so 3 items of 197 px are used instead (documented trade).
      expect(columnsFor(600, minItemWidth: 200, maxItemWidth: 280), 3);
      expect(columnsFor(1000, minItemWidth: 200, maxItemWidth: 280), 4);
    });

    test('gap is respected', () {
      // 2 items at 200 with a 40 px gap take 440 px.
      expect(columnsFor(440, minItemWidth: 200, maxItemWidth: 400, gap: 40), 2);
      expect(columnsFor(439, minItemWidth: 200, maxItemWidth: 400, gap: 40), 1);
    });
  });

  group('BoundedPage', () {
    Future<double> widthOf(WidgetTester tester, double window) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(window, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BoundedPage(
              child: Container(key: const Key('body'), height: 40),
            ),
          ),
        ),
      );
      return tester.getSize(find.byKey(const Key('body'))).width;
    }

    testWidgets('narrow window uses all width minus the gutters', (
      tester,
    ) async {
      expect(await widthOf(tester, 360), 360 - 2 * pageMinGutter);
    });

    testWidgets('wide window bounds the column and centres it', (tester) async {
      expect(await widthOf(tester, 1440), pageMaxWidth);
    });
  });
}
