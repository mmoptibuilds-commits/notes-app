import 'package:flutter_test/flutter_test.dart';
import 'package:notes/update/version_compare.dart';

void main() {
  group('SemVer.tryParse', () {
    test(
      'accepts valid versions and ignores build metadata when comparing',
      () {
        expect(SemVer.tryParse('1.0.0')!.toString(), '1.0.0');
        expect(SemVer.tryParse('1.2.3-rc.1')!.pre, ['rc', '1']);
        expect(
          SemVer.tryParse('1.0.0+abc')!
              .compareTo(SemVer.tryParse('1.0.0+xyz')!),
          0,
        );
        expect(
          SemVer.tryParse('1.0.0-alpha+001')!
              .compareTo(SemVer.tryParse('1.0.0-alpha')!),
          0,
        );
      },
    );

    test('rejects anything that is not strict semver', () {
      for (final bad in [
        '',
        'v1.0.0',
        '1.0',
        '1',
        '1.0.0.0',
        '01.0.0',
        '1.00.0',
        '1.0.0-',
        '1.0.0-01',
        '1.0.0-a..b',
        '1.0.0+',
        '1.0.0 ',
        ' 1.0.0',
        '1.0.0\n',
        '-1.0.0',
        '1.0.x',
        '99999999999.0.0',
        '1.0.0-ünï',
      ]) {
        expect(SemVer.tryParse(bad), isNull, reason: 'input "$bad"');
      }
    });
  });

  group('SemVer ordering', () {
    test('numeric parts compare as numbers, never as strings', () {
      expect(
        SemVer.tryParse('1.0.10')!.compareTo(SemVer.tryParse('1.0.9')!),
        greaterThan(0),
      );
      expect(
        SemVer.tryParse('1.10.0')!.compareTo(SemVer.tryParse('1.9.9')!),
        greaterThan(0),
      );
      expect(
        SemVer.tryParse('10.0.0')!.compareTo(SemVer.tryParse('9.99.99')!),
        greaterThan(0),
      );
    });

    test('pre-release precedence follows semver 2.0 section 11', () {
      const ladder = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ];
      for (var i = 0; i < ladder.length; i++) {
        for (var j = 0; j < ladder.length; j++) {
          final c = SemVer.tryParse(ladder[i])!
              .compareTo(SemVer.tryParse(ladder[j])!);
          expect(
            c.sign,
            i.compareTo(j).sign,
            reason: '${ladder[i]} vs ${ladder[j]}',
          );
        }
      }
    });

    test('a numeric identifier is lower than an alphanumeric one', () {
      expect(
        SemVer.tryParse('1.0.0-1')!.compareTo(SemVer.tryParse('1.0.0-a')!),
        lessThan(0),
      );
    });
  });

  group('isNewerLinuxVersion', () {
    bool newer(String inst, int ib, String cand, int cb) => isNewerLinuxVersion(
      installedVersion: inst,
      installedBuild: ib,
      candidateVersion: cand,
      candidateBuild: cb,
    );

    test('table', () {
      // installed, build, candidate, build, expected
      final rows = <(String, int, String, int, bool)>[
        ('1.0.0', 20261122, '1.0.1', 20261123, true),
        ('1.0.0', 20261122, '1.1.0', 1, true), // semver wins over build
        ('1.0.9', 5, '1.0.10', 5, true),
        ('1.0.0', 20261122, '1.0.0', 20261122, false), // equal
        ('1.0.0', 20261122, '1.0.0', 20261123, true), // tie-break on build
        ('1.0.0', 20261122, '1.0.0', 20261121, false),
        ('1.0.1', 20261122, '1.0.0', 99999999, false), // downgrade
        ('1.0.0-rc.1', 1, '1.0.0', 1, true), // release beats its rc
        ('1.0.0', 1, '1.0.0-rc.1', 99, false),
        ('1.0.0', 1, 'garbage', 99, false),
        ('1.0.0', 1, 'v1.0.1', 99, false),
        ('1.0.0+a', 5, '1.0.0+b', 5, false), // build metadata ignored
      ];
      for (final r in rows) {
        expect(
          newer(r.$1, r.$2, r.$3, r.$4),
          r.$5,
          reason: '${r.$1}+${r.$2} -> ${r.$3}+${r.$4}',
        );
      }
    });
  });

  group('isNewerAndroidVersionCode', () {
    test('table', () {
      bool n(int i, int c) => isNewerAndroidVersionCode(
        installedVersionCode: i,
        candidateVersionCode: c,
      );
      expect(n(20261122, 20261123), isTrue);
      expect(n(20261122, 20261122), isFalse);
      expect(n(20261122, 20261121), isFalse);
      expect(n(9, 10), isTrue); // numeric, not lexicographic
    });
  });

  test('compareReleases orders by version then build', () {
    expect(compareReleases('1.0.0', 5, '1.0.1', 1), lessThan(0));
    expect(compareReleases('1.0.1', 1, '1.0.1', 2), lessThan(0));
    expect(compareReleases('1.0.1', 2, '1.0.1', 2), 0);
    expect(compareReleases('1.0.10', 1, '1.0.9', 9), greaterThan(0));
  });
}
