/// Hybrid logical clock.
///
/// Orders events across devices whose wall clocks disagree. Encoded as a
/// fixed-width string so that plain string comparison is chronological:
/// `<millis: 12 hex><counter: 4 hex>-<node>`.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.node);

  /// Earlier than any real timestamp. Used for registers never written.
  static const zero = Hlc(0, 0, '');

  final int millis;
  final int counter;

  /// Device id (or a pseudo-device such as `legacy`) that produced the stamp.
  final String node;

  static const _maxCounter = 0xFFFF;

  factory Hlc.parse(String s) {
    if (s.length < 17 || s[16] != '-') {
      throw FormatException('Malformed HLC', s);
    }
    return Hlc(
      int.parse(s.substring(0, 12), radix: 16),
      int.parse(s.substring(12, 16), radix: 16),
      s.substring(17),
    );
  }

  String encode() =>
      '${millis.toRadixString(16).padLeft(12, '0')}'
      '${counter.toRadixString(16).padLeft(4, '0')}-$node';

  @override
  int compareTo(Hlc other) {
    if (millis != other.millis) return millis.compareTo(other.millis);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return node.compareTo(other.node);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.millis == millis &&
      other.counter == counter &&
      other.node == node;

  @override
  int get hashCode => Object.hash(millis, counter, node);

  @override
  String toString() => encode();
}

/// Issues monotonically increasing [Hlc] stamps for one device.
class HlcClock {
  HlcClock(this.node, {int Function()? wallClock, Hlc? last})
    : _wall = wallClock ?? _systemMillis,
      _last = last ?? Hlc(0, 0, node);

  final String node;
  final int Function() _wall;
  Hlc _last;

  static int _systemMillis() => DateTime.now().millisecondsSinceEpoch;

  /// The most recent stamp issued or observed.
  Hlc get last => _last;

  /// A new stamp, strictly greater than every stamp issued or observed so far.
  Hlc now() {
    final wall = _wall();
    if (wall > _last.millis) {
      _last = Hlc(wall, 0, node);
    } else if (_last.counter < Hlc._maxCounter) {
      _last = Hlc(_last.millis, _last.counter + 1, node);
    } else {
      _last = Hlc(_last.millis + 1, 0, node);
    }
    return _last;
  }

  /// Folds in a stamp seen from another device so later local stamps sort
  /// after it.
  void observe(Hlc remote) {
    if (remote.millis > _last.millis ||
        (remote.millis == _last.millis && remote.counter > _last.counter)) {
      _last = Hlc(remote.millis, remote.counter, node);
    }
  }
}
