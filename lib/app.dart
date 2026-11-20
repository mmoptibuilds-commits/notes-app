import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;

import 'platform/bootstrap.dart';
import 'ui/data/data_screen.dart';
import 'ui/editor/editor_screen.dart';
import 'ui/library/library_screen.dart';
import 'ui/material.dart';
import 'ui/onboarding/onboarding_screen.dart';
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
    // A database that already holds anything (an import, a restore, a paired
    // device) never needs the introduction, whatever the flag says.
    final settings = services.settings;
    if (settings.onboardingPending && settings.hasUserData) {
      settings.completeOnboarding();
    }
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
            // Quill's find dialog (Ctrl+F in the editor) throws without its
            // localizations.
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            theme: buildTheme(s),
            themeAnimationDuration: AppMotion(s.animations).medium,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: s.textScale == 1
                    ? MediaQuery.textScalerOf(context)
                    : _AppTextScaler(
                        MediaQuery.textScalerOf(context),
                        s.textScale,
                      ),
              ),
              child: child!,
            ),
            home: const _Root(),
          );
        },
      ),
    );
  }
}

/// The first screen: the one-time introduction on a genuinely new install,
/// the library otherwise. Any choice on the introduction marks it done, so it
/// is shown once; it never creates sample notes.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        if (!settings.onboardingPending) return const LibraryScreen();
        return OnboardingScreen(
          onCreateNote: () {
            settings.completeOnboarding();
            openEditor(context);
          },
          onImport: () {
            settings.completeOnboarding();
            Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const DataScreen()));
          },
          onSkip: settings.completeOnboarding,
        );
      },
    );
  }
}

/// Applies the user's app-level multiplier after the platform's text scaling.
/// Keeping the platform scaler intact preserves Android's nonlinear curve.
@immutable
class _AppTextScaler extends TextScaler {
  const _AppTextScaler(this.systemScaler, this.appScale);

  final TextScaler systemScaler;
  final double appScale;

  @override
  double scale(double fontSize) => systemScaler.scale(fontSize) * appScale;

  @override
  @Deprecated('Use scale instead.')
  double get textScaleFactor => systemScaler.textScaleFactor * appScale;

  @override
  bool operator ==(Object other) =>
      other is _AppTextScaler &&
      other.systemScaler == systemScaler &&
      other.appScale == appScale;

  @override
  int get hashCode => Object.hash(systemScaler, appScale);
}
