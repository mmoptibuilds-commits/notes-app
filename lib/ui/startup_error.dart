import '../data/app_database.dart';
import '../platform/bootstrap.dart';
import 'material.dart';

/// Shown instead of the app when the database cannot be opened. Offers no
/// destructive action: the user's file is left exactly as it is.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final (title, detail) = switch (error) {
      DatabaseKeyMissingException e => (
        'Your notes are locked',
        'The notes database is on this device, but its encryption key is no '
            'longer in the system keystore, so it cannot be opened.\n\n'
            'Nothing has been changed or deleted. If the keyring was reset or '
            'the app data was restored from a backup, restore the key or '
            'recover your notes from another paired device.\n\n'
            '${e.databasePath}',
      ),
      DatabaseUnreadableException e => (
        'Your notes could not be opened',
        'The stored key does not open the database. Nothing has been changed '
            'or deleted.\n\n${e.path}',
      ),
      DatabaseTooNewException e => (
        'This version of Notes is too old',
        'Your notes were last opened by a newer version of the app '
            '(data version ${e.found}, this app supports ${e.supported}). '
            'Install the newer version. Nothing has been changed.',
      ),
      _ => ('Notes could not start', '$error'),
    };
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true)
          .copyWith(scaffoldBackgroundColor: Colors.black),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(detail, style: const TextStyle(height: 1.4)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
