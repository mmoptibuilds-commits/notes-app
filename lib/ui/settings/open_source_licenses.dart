import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/app_version.dart';
import '../material.dart';
import '../shortcuts/shortcut_guards.dart';

Future<void>? _fontLicensesRegistration;
bool _fontLicensesReady = false;

/// Adds bundled font notices to Flutter's built-in licence page once.
Future<void> registerBundledFontLicenses() => _fontLicensesRegistration ??=
    _registerBundledFontLicenses().then((_) => _fontLicensesReady = true);

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
///
/// This mirrors Flutter's `showLicensePage` (same navigator, same captured
/// theme) but wraps the page in [backOnEscape], because the stock route does
/// not handle Escape on desktop. Escape goes back one level per keypress.
Future<void> openLicences(BuildContext context) async {
  final navigator = Navigator.of(context);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  // Once registered, skip the await: it keeps the open synchronous, so a
  // tap never depends on a microtask from an earlier zone.
  if (!_fontLicensesReady) await registerBundledFontLicenses();
  if (!navigator.mounted) return;
  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => backOnEscape(
        child: themes.wrap(
          const LicensePage(
            applicationName: 'Notes',
            applicationVersion: appVersionText,
          ),
        ),
      ),
    ),
  );
}
