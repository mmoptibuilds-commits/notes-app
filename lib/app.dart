import 'platform/bootstrap.dart';
import 'ui/library/library_screen.dart';
import 'ui/material.dart';
import 'ui/theme/app_theme.dart';

/// Gives every widget access to the app's services:
/// `AppScope.of(context).notes`, `.settings`, `.db`.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope old) => old.services != services;
}

class NotesApp extends StatelessWidget {
  const NotesApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: services,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final s = services.settings;
          return MaterialApp(
            title: 'Notes',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(s),
            themeAnimationDuration: AppMotion(s.animations).medium,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(s.textScale)),
              child: child!,
            ),
            home: const LibraryScreen(),
          );
        },
      ),
    );
  }
}
