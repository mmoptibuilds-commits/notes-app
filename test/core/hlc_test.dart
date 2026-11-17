import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/hlc.dart';

void main() {
  test('encoding round-trips and sorts chronologically as text', () {
    final a = Hlc(1700000000000, 0, 'aaaa');
    final b = Hlc(1700000000000, 1, 'aaaa');
    final c = Hlc(1700000000001, 0, 'aaaa');
    final d = Hlc(1700000000001, 0, 'bbbb');
    final sorted = [d, c, b, a]..sort();
    expect(sorted, [a, b, c, d]);
    final text = [d, c, b, a].map((h) => h.encode()).toList()..sort();
    expect(text, [a, b, c, d].map((h) => h.encode()).toList());
    for (final h in [a, b, c, d]) {
      expect(Hlc.parse(h.encode()), h);
    }
  });

  test('node may contain dashes and colons', () {
    final h = Hlc(5, 2, 'legacy:ab-cd');
    expect(Hlc.parse(h.encode()), h);
  });

  test('malformed text is rejected', () {
    expect(() => Hlc.parse('nope'), throwsFormatException);
    expect(() => Hlc.parse('0000000000000000xnode'), throwsFormatException);
  });

  test('clock is strictly monotonic when wall time stalls or goes back', () {
    var wall = 1000;
    final clock = HlcClock('n', wallClock: () => wall);
    final a = clock.now();
    final b = clock.now();
    wall = 500;
    final c = clock.now();
    wall = 2000;
    final d = clock.now();
    expect(a < b && b < c && c < d, isTrue);
    expect(d.millis, 2000);
    expect(d.counter, 0);
  });

  test('counter overflow rolls into the next millisecond', () {
    final clock = HlcClock(
      'n',
      wallClock: () => 1,
      last: const Hlc(10, 0xFFFF, 'n'),
    );
    final next = clock.now();
    expect(next, const Hlc(11, 0, 'n'));
  });

  test('observing a remote stamp pushes local stamps past it', () {
    final clock = HlcClock('me', wallClock: () => 1000);
    clock.observe(const Hlc(9000, 7, 'other'));
    final next = clock.now();
    expect(next > const Hlc(9000, 7, 'other'), isTrue);
    expect(next.node, 'me');
    clock.observe(const Hlc(10, 0, 'old'));
    expect(clock.now() > next, isTrue);
  });
}
