import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/app_version.dart';
import '../material.dart';

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

/// Shows the open-source licence page, with the bundled font notices added.
/// Used by Settings and Help.
Future<void> openLicences(BuildContext context) async {
  await registerBundledFontLicenses();
  if (!context.mounted) return;
  showLicensePage(
    context: context,
    applicationName: 'Notes',
    applicationVersion: appVersionText,
  );
}
