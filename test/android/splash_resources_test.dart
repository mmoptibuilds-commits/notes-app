import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The launch splash and window background must be black, matching the app's
/// default AMOLED theme, so that no white frame shows before Flutter draws.
/// Android 12 and later get the system splash with the same black background
/// and the launcher icon. These checks parse the resource XML (no Android
/// build is run here, so the aapt compile is not covered).
void main() {
  const res = 'android/app/src/main/res';
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';

  String read(String path) =>
      File(path)
          .readAsStringSync()
          .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  String resFile(String rel) => read('$res/$rel');

  /// The `<item name=...>value</item>` pairs of one `<style>`.
  Map<String, String> styleItems(String xml, String styleName) {
    final m = RegExp(
      '<style name="$styleName"([^>]*)>(.*?)</style>',
      dotAll: true,
    ).firstMatch(xml);
    expect(m, isNotNull, reason: 'missing style $styleName');
    final items = <String, String>{
      for (final i in RegExp(
        r'<item name="([^"]+)">([^<]*)</item>',
      ).allMatches(m!.group(2)!))
        i.group(1)!: i.group(2)!.trim(),
    };
    items['parent'] =
        RegExp('parent="([^"]*)"').firstMatch(m.group(1)!)?.group(1) ?? '';
    return items;
  }

  /// Every `<color name=...>` value across the values folders.
  Map<String, String> allColors() {
    final out = <String, String>{};
    final dir = Directory(res);
    for (final d in dir.listSync().whereType<Directory>()) {
      if (!d.path.split('/').last.startsWith('values')) continue;
      for (final f in d.listSync().whereType<File>()) {
        if (!f.path.endsWith('.xml')) continue;
        final xml = read(f.path);
        for (final m in RegExp(
          r'<color name="([^"]+)">\s*(#[0-9A-Fa-f]+)\s*</color>',
        ).allMatches(xml)) {
          out[m.group(1)!] = m.group(2)!.toUpperCase();
        }
      }
    }
    return out;
  }

  final colors = allColors();

  test('the splash colour is pure black', () {
    expect(colors['splash_background'], '#000000');
  });

  test('day and night launch and normal themes use black', () {
    for (final path in ['values/styles.xml', 'values-night/styles.xml']) {
      final xml = resFile(path);
      final launch = styleItems(xml, 'LaunchTheme');
      expect(
        launch['android:windowBackground'],
        '@drawable/launch_background',
        reason: path,
      );
      expect(launch['parent'], contains('Theme.Black'), reason: path);

      final normal = styleItems(xml, 'NormalTheme');
      expect(
        normal['android:windowBackground'],
        '@color/splash_background',
        reason: '$path NormalTheme must not fall back to the OS colour',
      );
      expect(normal['parent'], contains('Theme.Black'), reason: path);
    }
  });

  test(
    'legacy launch drawables are black, with no white or OS colour left',
    () {
      for (final path in [
        'drawable/launch_background.xml',
        'drawable-v21/launch_background.xml',
      ]) {
        final xml = resFile(path);
        expect(
          RegExp(r'android:drawable="@color/splash_background"').hasMatch(xml),
          isTrue,
          reason: path,
        );
        expect(xml, isNot(contains('white')), reason: path);
        expect(xml, isNot(contains('colorBackground')), reason: path);
      }
    },
  );

  for (final dir in ['values-v31', 'values-night-v31']) {
    test('$dir splash uses the black background and the launcher icon', () {
      final xml = resFile('$dir/styles.xml');
      final launch = styleItems(xml, 'LaunchTheme');
      expect(
        launch['android:windowSplashScreenBackground'],
        '@color/splash_background',
        reason: dir,
      );
      expect(
        launch['android:windowSplashScreenIconBackgroundColor'],
        '@color/splash_background',
        reason: dir,
      );
      expect(
        launch['android:windowSplashScreenAnimatedIcon'],
        '@mipmap/ic_launcher_foreground',
        reason: dir,
      );
      // postSplashScreenTheme belongs to androidx.core:core-splashscreen, not
      // the framework; aapt2 rejects it. The manifest selects NormalTheme.
      expect(
        launch.containsKey('android:postSplashScreenTheme'),
        isFalse,
        reason: dir,
      );
      expect(
        launch['android:windowBackground'],
        '@drawable/launch_background',
        reason: dir,
      );
    });
  }

  test('the launcher foreground exists at every density', () {
    final mipmaps = Directory(res)
        .listSync()
        .whereType<Directory>()
        .where((d) => RegExp(r'mipmap-[a-z]+dpi$').hasMatch(d.path));
    expect(mipmaps, isNotEmpty);
    for (final d in mipmaps) {
      expect(
        File('${d.path}/ic_launcher_foreground.png').existsSync(),
        isTrue,
        reason: d.path,
      );
    }
  });

  test('every colour and style reference resolves', () {
    final refColor = RegExp(r'@color/([A-Za-z0-9_]+)');
    final refStyle = RegExp(r'@style/([A-Za-z0-9_]+)');
    final styleNames = <String>{};
    final xmlFiles = <File>[];
    for (final d in Directory(res).listSync().whereType<Directory>()) {
      final name = d.path.split('/').last;
      if (!name.startsWith('values') && !name.startsWith('drawable')) continue;
      for (final f in d.listSync().whereType<File>()) {
        if (f.path.endsWith('.xml')) xmlFiles.add(f);
      }
    }
    for (final f in xmlFiles) {
      styleNames.addAll(
        RegExp(r'<style name="([^"]+)"')
            .allMatches(read(f.path))
            .map((m) => m.group(1)!),
      );
    }
    for (final f in xmlFiles) {
      final xml = read(f.path);
      for (final m in refColor.allMatches(xml)) {
        expect(
          colors.containsKey(m.group(1)),
          isTrue,
          reason: '${f.path} references @color/${m.group(1)}',
        );
      }
      for (final m in refStyle.allMatches(xml)) {
        expect(
          styleNames.contains(m.group(1)),
          isTrue,
          reason: '${f.path} references @style/${m.group(1)}',
        );
      }
    }
  });

  test('the manifest still names LaunchTheme and NormalTheme', () {
    final manifest = read(manifestPath);
    expect(manifest, contains('android:theme="@style/LaunchTheme"'));
    expect(manifest, contains('android:resource="@style/NormalTheme"'));
  });
}
