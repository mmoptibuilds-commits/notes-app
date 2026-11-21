import 'app.dart';
import 'platform/bootstrap.dart';
import 'ui/material.dart';
import 'ui/splash.dart';
import 'ui/startup_error.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw the splash at once; the database and keyring open behind it.
  runApp(
    Launcher(
      start: () async {
        try {
          return NotesApp(services: await bootstrap());
        } on Object catch (error) {
          return StartupErrorApp(error: error);
        }
      },
    ),
  );
}
