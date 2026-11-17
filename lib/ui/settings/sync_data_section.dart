import '../../app.dart';
import '../data/data_screen.dart';
import '../material.dart';
import '../sync/sync_screen.dart';
import '../theme/app_theme.dart';
import 'settings_widgets.dart';

/// Entry points to syncing and to import / export.
class SyncDataSection extends StatelessWidget {
  const SyncDataSection({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final app = AppScope.of(context);
    final sync = app.sync;
    void open(Widget page) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => page));
    final chevron = Icon(Icons.chevron_right_rounded, color: p.textFaint);
    return SettingsSection(
      title: 'Sync and data',
      rows: [
        if (sync != null)
          ListenableBuilder(
            listenable: sync,
            builder: (context, _) {
              final n = sync.peers.list().length;
              return SettingsRow(
                title: 'Sync with other devices',
                subtitle: n == 0
                    ? 'Not paired with any device'
                    : '$n paired ${n == 1 ? 'device' : 'devices'}',
                trailing: chevron,
                onTap: () => open(const SyncScreen()),
              );
            },
          ),
        SettingsRow(
          title: 'Import and export',
          subtitle: 'Bring in the old Notebook backup, or export all notes',
          trailing: chevron,
          onTap: () => open(const DataScreen()),
        ),
      ],
    );
  }
}
