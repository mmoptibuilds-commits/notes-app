import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The notes database is encrypted with a key held in the Android Keystore,
/// which is device-bound and never restored. If Android restored or transferred
/// the database (or the preferences that wrap the key) onto another install,
/// the app would hold a database it can never open. These checks fail if the
/// exclusions are removed. They read the source files, and the merged release
/// manifest when a build has produced one; they cannot prove what a particular
/// phone's backup service does.
void main() {
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';
  const rulesDir = 'android/app/src/main/res/xml';

  const legacyDomains = {'root', 'file', 'database', 'sharedpref', 'external'};
  const allDomains = {
    ...legacyDomains,
    'device_root',
    'device_file',
    'device_database',
    'device_sharedpref',
  };

  String read(String path) =>
      File(path)
          .readAsStringSync()
          .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  /// The `<application ...>` start tag.
  String applicationTag(String manifest) {
    final m = RegExp(
      r'<application\b[^>]*>',
      dotAll: true,
    ).firstMatch(manifest);
    expect(m, isNotNull, reason: 'no <application> element');
    return m!.group(0)!;
  }

  String? attr(String tag, String name) =>
      RegExp('$name\\s*=\\s*"([^"]*)"').firstMatch(tag)?.group(1);

  /// Domains excluded with path "." in [xml], and a failure if the block holds
  /// an include or any exclusion narrower than the whole domain.
  Set<String> excludedDomains(String xml) {
    expect(
      xml,
      isNot(contains('<include')),
      reason: 'an include re-enables data',
    );
    final out = <String>{};
    for (final m in RegExp(r'<exclude\b([^>]*?)/?>').allMatches(xml)) {
      final domain = attr(m.group(1)!, 'domain');
      final path = attr(m.group(1)!, 'path');
      expect(
        path,
        '.',
        reason: 'exclusion of $domain must cover the whole domain',
      );
      out.add(domain!);
    }
    return out;
  }

  void expectProtected(String tag, {required String where}) {
    expect(attr(tag, 'android:allowBackup'), 'false', reason: where);
    expect(
      attr(tag, 'android:fullBackupContent'),
      '@xml/backup_rules',
      reason: where,
    );
    expect(
      attr(tag, 'android:dataExtractionRules'),
      '@xml/data_extraction_rules',
      reason: where,
    );
  }

  test('source manifest disables backup and points at both rule files', () {
    expectProtected(
      applicationTag(read(manifestPath)),
      where: 'AndroidManifest.xml',
    );
  });

  test('Android 11 and earlier rules exclude every domain', () {
    final xml = read('$rulesDir/backup_rules.xml');
    expect(xml, contains('<full-backup-content'));
    expect(excludedDomains(xml), legacyDomains);
  });

  test('Android 12+ rules exclude every domain from backup and transfer', () {
    final xml = read('$rulesDir/data_extraction_rules.xml');
    expect(xml, contains('<data-extraction-rules'));
    for (final section in ['cloud-backup', 'device-transfer']) {
      final m = RegExp(
        '<$section\\b[^>]*>(.*?)</$section>',
        dotAll: true,
      ).firstMatch(xml);
      expect(m, isNotNull, reason: 'missing <$section>');
      expect(excludedDomains(m!.group(1)!), allDomains, reason: section);
    }
  });

  test('no cross-platform transfer is declared without an iOS counterpart', () {
    final xml = read('$rulesDir/data_extraction_rules.xml');
    expect(xml, isNot(contains('<cross-platform-transfer')));
    expectProtected(
      applicationTag(read(manifestPath)),
      where: 'AndroidManifest.xml',
    );
    for (final section in ['cloud-backup', 'device-transfer']) {
      final m = RegExp(
        '<$section\\b[^>]*>(.*?)</$section>',
        dotAll: true,
      ).firstMatch(xml);
      expect(m, isNotNull, reason: 'missing <$section>');
      expect(excludedDomains(m!.group(1)!), allDomains, reason: section);
    }
  });

  group('merged release manifest', () {
    // Produced by `flutter build apk --release`; absent on a fresh checkout.
    final merged = Directory('build/app/intermediates').existsSync()
        ? Directory('build/app/intermediates')
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) =>
                    f.path.endsWith('AndroidManifest.xml') &&
                    f.path.contains('merged_manifest') &&
                    f.path.toLowerCase().contains('release'),
              )
              .map((f) => f.path)
              .toList()
        : <String>[];

    test(
      'keeps the protections after manifest merging',
      () {
        for (final path in merged) {
          expectProtected(applicationTag(read(path)), where: path);
        }
      },
      skip: merged.isEmpty
          ? 'no release build output; run a release build'
          : false,
    );
  });
}
