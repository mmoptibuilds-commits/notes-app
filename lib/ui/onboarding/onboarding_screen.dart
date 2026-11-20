import '../material.dart';
import '../theme/app_theme.dart';
import 'welcome_points.dart';

/// The one-screen introduction shown on first run. It only reports what the
/// person chose; the caller decides what happens and marks the introduction
/// done. It never creates sample notes.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({
    super.key,
    required this.onCreateNote,
    required this.onImport,
    required this.onSkip,
  });

  final VoidCallback onCreateNote;
  final VoidCallback onImport;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'Welcome to Notes',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const WelcomeList(),
                  const SizedBox(height: 12),
                  // Standard density keeps the 48dp minimum; the buttons grow
                  // with text scale rather than clipping.
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 48),
                      visualDensity: VisualDensity.standard,
                    ),
                    onPressed: onCreateNote,
                    child: const Text('Create a note'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(64, 48),
                      visualDensity: VisualDensity.standard,
                      side: BorderSide(color: p.cardBorder),
                    ),
                    onPressed: onImport,
                    child: const Text('Import notes'),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(64, 48),
                      visualDensity: VisualDensity.standard,
                    ),
                    onPressed: onSkip,
                    child: const Text('Skip'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
