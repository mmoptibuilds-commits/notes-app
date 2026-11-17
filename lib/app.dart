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

class NotesApp extends StatefulWidget {
  const NotesApp({super.key, required this.services});

  final AppServices services;

  @override
  State<NotesApp> createState() => _NotesAppState();
}

class _NotesAppState extends State<NotesApp> with WidgetsBindingObserver {
  AppServices get services => widget.services;

  @override
  void initState() {
    super.initState();
    final sync = services.sync;
    if (sync == null) return;
    WidgetsBinding.instance.addObserver(this);
    // Catch up with paired devices shortly after the app opens.
    sync.start().then(
      (_) => sync.requestAutoSync(after: const Duration(seconds: 2)),
    );
    services.notes.changes.addListener(_onLocalChange);
  }

  void _onLocalChange() {
    final sync = services.sync;
    // Edits (not the changes a sync itself just applied) are pushed out once
    // typing has settled; devices that are away are not retried eagerly.
    if (sync != null && !sync.syncing) {
      sync.requestAutoSync(after: const Duration(seconds: 20));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final sync = services.sync;
    if (sync == null) return;
    if (state == AppLifecycleState.resumed) {
      sync.start().then(
        (_) => sync.requestAutoSync(after: const Duration(seconds: 1)),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    services.notes.changes.removeListener(_onLocalChange);
    super.dispose();
  }

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
