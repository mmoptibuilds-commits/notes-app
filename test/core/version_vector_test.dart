import 'package:flutter_test/flutter_test.dart';
import 'package:notes/core/ids.dart';
import 'package:notes/core/version_vector.dart';

void main() {
  test('compare', () {
    final a = VersionVector({'x': 1});
    final b = a.increment('x');
    final c = a.increment('y');
    expect(a.compare(a), VvOrder.equal);
    expect(b.compare(a), VvOrder.dominates);
    expect(a.compare(b), VvOrder.dominated);
    expect(b.compare(c), VvOrder.concurrent);
    expect(VersionVector.empty.compare(a), VvOrder.dominated);
  });

  test('merge is the pointwise maximum and dominates both inputs', () {
    final b = VersionVector({'x': 2, 'z': 1});
    final c = VersionVector({'x': 1, 'y': 3});
    final m = b.merge(c);
    expect(m.counters, {'x': 2, 'y': 3, 'z': 1});
    expect(m.compare(b), VvOrder.dominates);
    expect(m.compare(c), VvOrder.dominates);
    expect(c.merge(b), m);
  });

  test('encoding is canonical regardless of insertion order', () {
    final a = VersionVector({'b': 2, 'a': 1});
    final b = VersionVector({'a': 1, 'b': 2});
    expect(a.encode(), b.encode());
    expect(a, b);
    expect(VersionVector.decode(a.encode()), a);
    expect(VersionVector({'a': 0}).encode(), '{}');
  });

  test('ids', () {
    final ids = {for (var i = 0; i < 1000; i++) newId()};
    expect(ids.length, 1000);
    expect(
      ids.first,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(derivedId('ns', ['a', 'b']), derivedId('ns', ['a', 'b']));
    expect(derivedId('ns', ['a', 'b']), isNot(derivedId('ns', ['ab'])));
    expect(derivedId('ns', ['a']), isNot(derivedId('other', ['a'])));
    expect(newDeviceId(), hasLength(16));
  });
}
