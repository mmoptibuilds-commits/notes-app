import '../material.dart';
import '../theme/app_theme.dart';

/// One short statement shown on the first-run screen and in Help's Welcome
/// topic. Both read [welcomePoints], so the two cannot drift apart.
class WelcomePoint {
  const WelcomePoint({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

const welcomePoints = <WelcomePoint>[
  WelcomePoint(
    icon: Icons.wifi_off_rounded,
    title: 'Works offline',
    body: 'Everything in Notes works without a network connection.',
  ),
  WelcomePoint(
    icon: Icons.lock_outline_rounded,
    title: 'Stored on this device',
    body: 'Your notes live in an encrypted database on this device.',
  ),
  WelcomePoint(
    icon: Icons.file_open_outlined,
    title: 'Import an existing backup',
    body: 'Bring in a backup from the old Notebook app, or a Notes export.',
  ),
  WelcomePoint(
    icon: Icons.devices_rounded,
    title: 'Pair your own devices',
    body:
        'Pair up to four other devices of yours. They sync directly over '
        'the same network.',
  ),
  WelcomePoint(
    icon: Icons.person_off_outlined,
    title: 'No account needed',
    body: 'There is no sign-in and no cloud. Nothing is sent to a server.',
  ),
];

/// The [welcomePoints] as a column of icon, title and text.
class WelcomeList extends StatelessWidget {
  const WelcomeList({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final point in welcomePoints)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(point.icon, size: 24, color: p.accent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        point.title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                          color: p.text,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        point.body,
                        style: TextStyle(
                          fontSize: 14.5,
                          height: 1.45,
                          color: p.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
