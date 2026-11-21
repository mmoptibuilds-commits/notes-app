import 'dart:math' as math;

import '../../app.dart';
import '../../core/app_version.dart';
import '../../data/app_settings.dart';
import '../../data/note_repository.dart' show NoteSort;
import '../help/help_screen.dart';
import '../help/help_shortcuts.dart';
import '../material.dart';
import '../shortcuts/shortcut_defs.dart';
import '../shortcuts/shortcut_guards.dart';
import '../updates/updates_screen.dart';
import '../theme/app_theme.dart';
import 'open_source_licenses.dart';
import 'settings_widgets.dart';
import 'sync_data_section.dart';
import 'toolbar_settings_screen.dart';

const _pageMaxWidth = 640.0;

/// App version shown in About.

/// The sections of the settings page, in order. Append new ones here.
List<Widget> settingsSections() => const [
  AppearanceSection(),
  LibrarySection(),
  EditorSection(),
  SyncDataSection(),
  AboutSection(),
];

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return shortcutScope(
      scopes: const {ShortcutScope.global},
      autofocus: true,
      handlers: {
        ShortcutId.escape: () => escapeOrLeave(context),
        ShortcutId.openHelp: () => openHelp(context),
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: LayoutBuilder(
          builder: (context, cons) {
            final side = math.max(12.0, (cons.maxWidth - _pageMaxWidth) / 2);
            return ListenableBuilder(
              listenable: settings,
              builder: (context, _) => ListView(
                padding: EdgeInsets.fromLTRB(side, 0, side, 32),
                children: settingsSections(),
              ),
            );
          },
        ),
      ),
    );
  }
}

String _themeLabel(AppTheme t) => switch (t) {
  AppTheme.amoled => 'AMOLED',
  AppTheme.charcoal => 'Charcoal',
  AppTheme.light => 'Light',
};

String _animLabel(AnimationLevel a) => switch (a) {
  AnimationLevel.off => 'Off',
  AnimationLevel.reduced => 'Reduced',
  AnimationLevel.full => 'Full',
};

String _layoutLabel(LibraryLayout l) => switch (l) {
  LibraryLayout.grid => 'Grid',
  LibraryLayout.masonry => 'Masonry',
  LibraryLayout.list => 'List',
};

String _startupViewLabel(StartupView view) => switch (view) {
  StartupView.unfiled => 'Unfiled',
  StartupView.all => 'All notes',
  StartupView.last => 'Last viewed',
};

String _sortLabel(NoteSort s) => switch (s) {
  NoteSort.modified => 'Modified',
  NoteSort.created => 'Created',
  NoteSort.title => 'Title',
};

String _fontLabel(AppFont f) => f.label;

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsBuilder(
      builder: (context, s) => SettingsSection(
        title: 'Appearance',
        rows: [
          SegmentedRow<AppTheme>(
            title: 'Theme',
            values: AppTheme.values,
            labelOf: _themeLabel,
            value: s.theme,
            onChanged: (v) => s.theme = v,
          ),
          MenuRow<AppFont>(
            title: 'Interface font',
            values: AppFont.values,
            labelOf: _fontLabel,
            value: s.uiFont,
            onChanged: (v) => s.uiFont = v,
          ),
          _TextScaleRow(settings: s),
          SegmentedRow<AnimationLevel>(
            title: 'Animations',
            values: AnimationLevel.values,
            labelOf: _animLabel,
            value: s.animations,
            onChanged: (v) => s.animations = v,
          ),
        ],
      ),
    );
  }
}

/// Previews the scale locally while dragging and commits on release, so the
/// slider is not rescaled under the pointer.
class _TextScaleRow extends StatefulWidget {
  const _TextScaleRow({required this.settings});
  final AppSettings settings;

  @override
  State<_TextScaleRow> createState() => _TextScaleRowState();
}

class _TextScaleRowState extends State<_TextScaleRow> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final v = _drag ?? widget.settings.textScale;
    final p = AppPalette.of(context);
    return Column(
      children: [
        SliderRow(
          title: 'Interface text size',
          value: v,
          min: 0.85,
          max: 1.4,
          divisions: 11,
          label: '${(v * 100).round()}%',
          onChangeStart: (_) => _drag = v,
          onChanged: (x) {
            if (_drag == null) {
              widget.settings.textScale = x;
            } else {
              setState(() => _drag = x);
            }
          },
          onChangeEnd: (x) {
            widget.settings.textScale = x;
            setState(() => _drag = null);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(v)),
              child: Text(
                'The quick brown fox jumps over the lazy dog',
                style: TextStyle(fontSize: 14, color: p.textMuted),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class LibrarySection extends StatelessWidget {
  const LibrarySection({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsBuilder(
      builder: (context, s) => SettingsSection(
        title: 'Library',
        rows: [
          SegmentedRow<StartupView>(
            title: 'Start in',
            values: StartupView.values,
            labelOf: _startupViewLabel,
            value: s.startupView,
            onChanged: (v) => s.startupView = v,
          ),
          SegmentedRow<LibraryLayout>(
            title: 'Layout',
            values: LibraryLayout.values,
            labelOf: _layoutLabel,
            value: s.layout,
            onChanged: (v) => s.layout = v,
          ),
          SegmentedRow<NoteSort>(
            title: 'Sort by',
            values: NoteSort.values,
            labelOf: _sortLabel,
            value: s.sort,
            onChanged: (v) => s.sort = v,
          ),
          SliderRow(
            title: 'Preview lines',
            value: s.previewLines.toDouble(),
            min: 0,
            max: 10,
            divisions: 10,
            label: s.previewLines == 0 ? 'None' : '${s.previewLines}',
            onChanged: (v) => s.previewLines = v.round(),
          ),
        ],
      ),
    );
  }
}

class EditorSection extends StatelessWidget {
  const EditorSection({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return SettingsBuilder(
      builder: (context, s) => SettingsSection(
        title: 'Editor',
        rows: [
          MenuRow<AppFont>(
            title: 'Note font',
            values: AppFont.values,
            labelOf: _fontLabel,
            value: s.editorFont,
            onChanged: (v) => s.editorFont = v,
          ),
          SliderRow(
            title: 'Note text size',
            value: s.editorFontSize,
            min: 12,
            max: 28,
            divisions: 16,
            label: '${s.editorFontSize.round()} px',
            onChanged: (v) => s.editorFontSize = v.roundToDouble(),
          ),
          SliderRow(
            title: 'Line height',
            value: s.editorLineHeight,
            min: 1.1,
            max: 2.0,
            divisions: 18,
            label: s.editorLineHeight.toStringAsFixed(2),
            onChanged: (v) => s.editorLineHeight = (v * 20).round() / 20,
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Text(
              'Sample note text. Checklists, headings and plain paragraphs all '
              'use this font, size and spacing.',
              style: TextStyle(
                fontFamily: s.editorFont.family,
                fontSize: s.editorFontSize,
                height: s.editorLineHeight,
                color: p.text,
              ),
            ),
          ),
          SwitchRow(
            title: 'Move completed checklist items to a collapsible section',
            value: s.completedSection,
            onChanged: (v) => s.completedSection = v,
          ),
          SwitchRow(
            title: 'Start with completed section collapsed',
            value: s.completedCollapsed,
            onChanged: (v) => s.completedCollapsed = v,
          ),
          SettingsRow(
            title: 'Customise toolbar',
            subtitle:
                '${s.toolbar.length} of ${ToolbarItem.values.length} buttons shown',
            trailing: Icon(Icons.chevron_right_rounded, color: p.textFaint),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ToolbarSettingsScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the Help screen, with the shortcut list taken from the shared
/// definitions. Used by Settings and by the F1 shortcut.
Future<void> openHelp(BuildContext context) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => HelpScreen(
      shortcuts: helpShortcuts(),
      appVersion: appVersionText,
      onOpenLicences: () => openLicences(context),
    ),
  ),
);

class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final dir = AppScope.of(context).dataDir;
    final chevron = Icon(Icons.chevron_right_rounded, color: p.textFaint);
    return SettingsSection(
      title: 'About',
      rows: [
        SettingsRow(
          title: 'Help',
          subtitle: 'Setup, sync, backups, pairing and troubleshooting',
          semanticLabel: 'Help',
          minimumHeight: 30,
          trailing: chevron,
          onTap: () => openHelp(context),
        ),
        if (AppScope.of(context).updates != null)
          SettingsRow(
            title: 'App updates',
            subtitle: 'Check for a newer version',
            semanticLabel: 'App updates',
            minimumHeight: 30,
            trailing: chevron,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => UpdatesScreen(
                  controller: AppScope.of(context).updates!,
                  settings: AppScope.of(context).settings,
                ),
              ),
            ),
          ),
        SettingsRow(
          title: 'Notes',
          trailing: Text(
            'Version $appVersionText',
            style: TextStyle(fontSize: 13.5, color: p.textMuted),
          ),
        ),
        SettingsRow(
          title: 'Open-source licences',
          semanticLabel: 'Open-source licences',
          minimumHeight: 30,
          trailing: chevron,
          onTap: () => openLicences(context),
        ),
        if (dir.isNotEmpty)
          SettingsRow(
            title: 'Data folder',
            below: SelectableText(
              dir,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: p.textMuted),
            ),
          ),
      ],
    );
  }
}
