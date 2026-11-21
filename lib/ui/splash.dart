import 'brand_mark.dart';
import 'material.dart';

/// The first thing drawn at launch, while the encrypted database and the
/// keyring open. It is shown only for as long as startup takes (no fixed
/// delay) and matches the platform launch screens: the app glyph on black.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: brandBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NoteGlyph(size: 150),
            SizedBox(height: 4),
            Text(
              'Notes',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 26,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                color: Color(0xFFE8E9F3),
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows [SplashScreen] until [start] completes, then cross-fades to the app
/// it built. Respects the system "reduce motion" setting.
class Launcher extends StatefulWidget {
  const Launcher({super.key, required this.start});

  /// Opens everything the app needs and returns the widget to show.
  final Future<Widget> Function() start;

  @override
  State<Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<Launcher> {
  Widget? _app;

  @override
  void initState() {
    super.initState();
    widget.start().then((app) {
      if (mounted) setState(() => _app = app);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQueryData.fromView(View.of(context)).disableAnimations;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: AnimatedSwitcher(
        duration: reduce ? Duration.zero : const Duration(milliseconds: 220),
        child: _app ?? const SplashScreen(key: ValueKey('splash')),
      ),
    );
  }
}
