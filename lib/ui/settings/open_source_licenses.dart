import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

Future<void>? _fontLicensesRegistration;

/// Adds bundled font notices to Flutter's built-in licence page once.
Future<void> registerBundledFontLicenses() =>
    _fontLicensesRegistration ??= _registerBundledFontLicenses();

Future<void> _registerBundledFontLicenses() async {
  const licenses = <(String, String)>[
    ('Inter (font)', 'assets/fonts/Inter-OFL.txt'),
    ('Source Serif 4 (font)', 'assets/fonts/SourceSerif4-OFL.txt'),
    ('JetBrains Mono (font)', 'assets/fonts/JetBrainsMono-OFL.txt'),
    (
      'Atkinson Hyperlegible (font)',
      'assets/fonts/AtkinsonHyperlegible-OFL.txt',
    ),
  ];

  for (final (package, asset) in licenses) {
    final text = await rootBundle.loadString(asset);
    LicenseRegistry.addLicense(
      () => Stream<LicenseEntry>.value(
        LicenseEntryWithLineBreaks([package], text),
      ),
    );
  }
}
