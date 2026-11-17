import 'app.dart';
import 'platform/bootstrap.dart';
import 'ui/material.dart';
import 'ui/startup_error.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    runApp(NotesApp(services: await bootstrap()));
  } on Object catch (error) {
    runApp(StartupErrorApp(error: error));
  }
}
