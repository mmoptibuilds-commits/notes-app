import '../../data/app_settings.dart';
import '../../update/installer.dart';
import '../../update/update_controller.dart';
import '../../update/update_status.dart';
import '../material.dart';
import '../settings/settings_widgets.dart';
import '../shortcuts/shortcut_guards.dart';
import '../theme/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/touch.dart';

/// Release notes are shown as plain text, at most this long.
const kMaxNotesShown = 1500;

/// Sanitises release notes for display: control characters removed, runs of
/// blank lines collapsed, and cut at [limit] characters with an ellipsis.
String displayNotes(String raw, {int limit = kMaxNotesShown}) {
  var s = raw
      .replaceAll('\r\n', '\n')
      .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  if (s.length > limit) {
    // Do not cut a surrogate pair in half.
    var end = limit;
    if (s.codeUnitAt(end - 1) >= 0xD800 && s.codeUnitAt(end - 1) <= 0xDBFF) {
      end--;
    }
    s = '${s.substring(0, end).trimRight()}…';
  }
  return s;
}

/// "12.3 MB".
String formatSize(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _ago(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) {
    return d.inMinutes == 1 ? '1 minute ago' : '${d.inMinutes} minutes ago';
  }
  if (d.inHours < 24) {
    return d.inHours == 1 ? '1 hour ago' : '${d.inHours} hours ago';
  }
  final l = then.toLocal();
  const m = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${l.day} ${m[l.month - 1]} ${l.year}';
}

String _clock(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:'
      '${l.minute.toString().padLeft(2, '0')}';
}

/// The shared Updates screen (Android and Linux). Reads everything from
/// [controller]; the automatic-check switch is bound to [settings].
class UpdatesScreen extends StatelessWidget {
  const UpdatesScreen({
    super.key,
    required this.controller,
    required this.settings,
    this.clock = DateTime.now,
  });

  final UpdateController controller;
  final AppSettings settings;
  final DateTime Function() clock;

  @override
  Widget build(BuildContext context) {
    return backOnEscape(
      child: Scaffold(
        appBar: AppBar(title: const Text('Updates')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListenableBuilder(
              listenable: Listenable.merge([controller, settings]),
              builder: (context, _) => _Body(
                controller: controller,
                settings: settings,
                now: clock(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    required this.settings,
    required this.now,
  });

  final UpdateController controller;
  final AppSettings settings;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final outcome = controller.lastOutcome;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
      children: [
        _Card(
          children: [
            SettingsRow(
              title: 'Notes ${controller.installedVersion}',
              subtitle:
                  'Build ${controller.installedBuild}  ·  Channel: Stable',
              minimumHeight: 40,
            ),
          ],
        ),
        if (outcome != null) ...[
          const SizedBox(height: 12),
          _Card(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(
                  children: [
                    Icon(
                      outcome.updated
                          ? Icons.check_circle_outline_rounded
                          : Icons.info_outline_rounded,
                      size: 20,
                      color: outcome.updated ? p.accent : p.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          outcome.message,
                          style: TextStyle(fontSize: 13.5, color: p.text),
                        ),
                      ),
                    ),
                    IconButton(
                      style: IconButton.styleFrom(
                        minimumSize: Size.square(hitSize(context)),
                        visualDensity: VisualDensity.standard,
                      ),
                      tooltip: 'Dismiss',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: controller.dismissOutcome,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _StatusCard(controller: controller, now: now),
        const SizedBox(height: 12),
        _Card(
          children: [
            SwitchRow(
              title: 'Automatically check about once a day',
              subtitle:
                  'Contacts api.github.com over HTTPS to ask for the latest '
                  'release. No personal data is sent. Updates are never '
                  'downloaded or installed without you asking.',
              value: settings.autoCheckUpdates,
              onChanged: (v) => settings.autoCheckUpdates = v,
            ),
          ],
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Material(
      color: p.card,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
        side: BorderSide(color: p.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _Line {
  const _Line(this.icon, this.title, {this.detail, this.error = false});
  final IconData icon;
  final String title;
  final String? detail;
  final bool error;
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller, required this.now});

  final UpdateController controller;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final s = controller.status;
    final line = _lineFor(s);
    final candidate = _candidateOf(s);
    final last = controller.lastSuccessfulCheck;
    return _Card(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s is UpdateChecking)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      line.icon,
                      size: 20,
                      color: line.error ? p.danger : p.accent,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      container: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            line.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: line.error ? p.danger : p.text,
                            ),
                          ),
                          if (line.detail != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                line.detail!,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: p.textMuted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (s is UpdateDownloading) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: s.fraction,
                  semanticsLabel: 'Download progress',
                ),
                const SizedBox(height: 6),
                Text(
                  '${formatSize(s.received)} of ${formatSize(s.total)}',
                  style: TextStyle(fontSize: 12, color: p.textMuted),
                ),
              ],
              if (candidate != null) ...[
                const SizedBox(height: 12),
                _Details(candidate: candidate),
              ],
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: _actions(context, s)),
              const SizedBox(height: 10),
              Text(
                last == null
                    ? 'Not checked yet'
                    : 'Last checked: ${_ago(last, now)}',
                style: TextStyle(fontSize: 12, color: p.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  UpdateCandidate? _candidateOf(UpdateStatus s) => switch (s) {
    UpdateAvailable(:final candidate) => candidate,
    UpdateDownloading(:final candidate) => candidate,
    UpdateReadyToInstall(:final candidate) => candidate,
    UpdateInstalling(:final candidate) => candidate,
    UpdateInstallationHandedToOs(:final candidate) => candidate,
    UpdateBlocked(:final candidate) => candidate,
    UpdateFailed(:final candidate) => candidate,
    _ => null,
  };

  _Line _lineFor(UpdateStatus s) => switch (s) {
    UpdateIdle() => const _Line(
      Icons.system_update_alt_rounded,
      'Updates have not been checked yet',
    ),
    UpdateChecking() => const _Line(
      Icons.sync_rounded,
      'Checking for updates…',
    ),
    UpdateUpToDate() => _Line(
      Icons.check_circle_outline_rounded,
      'Notes is up to date',
      detail:
          'Version ${controller.installedVersion} is the latest stable '
          'release.',
    ),
    UpdateNoStableRelease() => const _Line(
      Icons.info_outline_rounded,
      'No stable release published',
      detail: 'Only pre-releases exist so far, and Notes does not offer those.',
    ),
    UpdateNoPlatformRelease() => const _Line(
      Icons.info_outline_rounded,
      'No download for this device',
      detail: 'The latest release has no file for this device yet.',
    ),
    UpdateOffline() => const _Line(
      Icons.cloud_off_rounded,
      'Cannot reach GitHub',
      detail: 'Check your internet connection and try again.',
      error: true,
    ),
    UpdateRateLimited(:final resetAt) => _Line(
      Icons.hourglass_bottom_rounded,
      'GitHub is limiting requests',
      detail: resetAt == null
          ? 'Try again in a little while.'
          : 'Try again after ${_clock(resetAt)}.',
    ),
    UpdateFailed(:final message, :final candidate) => _Line(
      Icons.error_outline_rounded,
      candidate == null ? 'The update check failed' : 'The update failed',
      detail: message,
      error: true,
    ),
    UpdateAvailable(:final candidate) => _Line(
      Icons.system_update_alt_rounded,
      'Version ${candidate.version} is available',
      detail: 'Nothing is downloaded until you choose to.',
    ),
    UpdateDownloading(:final candidate) => _Line(
      Icons.download_rounded,
      'Downloading version ${candidate.version}…',
    ),
    UpdateReadyToInstall(:final candidate, :final message) => _Line(
      Icons.verified_outlined,
      'Version ${candidate.version} is ready to install',
      detail: message == null
          ? 'The download was checked against its checksum.'
          : 'The last attempt did not finish: $message',
      error: message != null,
    ),
    UpdateVerificationFailed(:final reason) => _Line(
      Icons.gpp_bad_outlined,
      'Could not verify the update',
      detail: '$reason Nothing was installed.',
      error: true,
    ),
    UpdateInstalling(:final candidate) => _Line(
      Icons.sync_rounded,
      'Starting the installation of ${candidate.version}…',
    ),
    UpdateInstallationHandedToOs(:final candidate, :final willRestart) => _Line(
      Icons.hourglass_top_rounded,
      willRestart
          ? 'Notes is restarting to finish the update'
          : 'Waiting for Android to finish installing ${candidate.version}',
      detail: willRestart
          ? 'Notes will reopen by itself. If it does not, start it again.'
          : 'Follow the Android prompt. If you dismissed it, you can install '
                'again. Notes will say whether the update went through the '
                'next time it opens.',
    ),
    UpdateBlocked(:final block, :final candidate) => _Line(
      Icons.block_rounded,
      candidate == null
          ? 'Updates cannot be installed here'
          : 'Version ${candidate.version} is available, but cannot be '
                'installed from here',
      detail: _guidance(block),
      error: block.kind != BlockKind.installPermission,
    ),
  };

  String _guidance(UpdateBlock b) => switch (b.kind) {
    BlockKind.signingKeyNotProvisioned =>
      'This build of Notes cannot verify downloads yet because the release '
          'signing key has not been set up. Nothing is downloaded. Install '
          'the new version by hand from the Notes releases page.',
    BlockKind.installPermission =>
      '${b.message} Open the Android setting, allow Notes to install apps, '
          'come back and press Try again.',
    _ => b.message,
  };

  ButtonStyle _filled(BuildContext context) => FilledButton.styleFrom(
    minimumSize: Size(64, hitSize(context)),
    visualDensity: VisualDensity.standard,
  );

  ButtonStyle _outlined(BuildContext context) => OutlinedButton.styleFrom(
    minimumSize: Size(64, hitSize(context)),
    visualDensity: VisualDensity.standard,
  );

  bool _restarting(UpdateStatus s) =>
      s is UpdateInstallationHandedToOs && s.willRestart;

  List<Widget> _actions(BuildContext context, UpdateStatus s) {
    final c = controller;
    Widget check(String label, {bool primary = false}) {
      final onPressed = c.busy || _restarting(s) ? null : () => c.check();
      return primary
          ? FilledButton(
              style: _filled(context),
              onPressed: onPressed,
              child: Text(label),
            )
          : OutlinedButton(
              style: _outlined(context),
              onPressed: onPressed,
              child: Text(label),
            );
    }

    return switch (s) {
      UpdateAvailable() => [
        FilledButton(
          style: _filled(context),
          onPressed: c.download,
          child: const Text('Download'),
        ),
        check('Check again'),
      ],
      UpdateDownloading() => [
        OutlinedButton(
          style: _outlined(context),
          onPressed: c.cancelDownload,
          child: const Text('Cancel'),
        ),
      ],
      UpdateReadyToInstall(:final candidate) => [
        FilledButton(
          style: _filled(context),
          onPressed: () => _confirmInstall(context, candidate),
          child: const Text('Install…'),
        ),
        check('Check again'),
      ],
      UpdateInstalling() => const [],
      UpdateInstallationHandedToOs(:final candidate, :final willRestart) =>
        willRestart
            ? const []
            : [
                FilledButton(
                  style: _filled(context),
                  onPressed: () => _confirmInstall(context, candidate),
                  child: const Text('Install again'),
                ),
                check('Check again'),
              ],
      UpdateFailed(candidate: != null) => [
        FilledButton(
          style: _filled(context),
          onPressed: c.download,
          child: const Text('Retry'),
        ),
        check('Check again'),
      ],
      UpdateOffline() ||
      UpdateRateLimited() ||
      UpdateFailed() ||
      UpdateVerificationFailed() => [check('Try again', primary: true)],
      UpdateBlocked(:final block, :final candidate)
          when block.kind == BlockKind.installPermission =>
        [
          FilledButton(
            style: _filled(context),
            onPressed: c.openInstallSettings,
            child: const Text('Open Android settings'),
          ),
          OutlinedButton(
            style: _outlined(context),
            onPressed: candidate == null ? null : c.install,
            child: const Text('Try again'),
          ),
        ],
      UpdateIdle() ||
      UpdateChecking() => [check('Check for updates', primary: true)],
      _ => [check('Check for updates')],
    };
  }

  Future<void> _confirmInstall(
    BuildContext context,
    UpdateCandidate candidate,
  ) async {
    final android = candidate.platform.os == UpdateOs.android;
    final ok = await confirmDialog(
      context,
      title: 'Install version ${candidate.version}?',
      message: android
          ? 'Android will ask you to confirm the installation. Your notes stay '
                'on this phone.'
          : 'Notes will close, update itself and reopen. Your notes are '
                'stored separately and are not touched.',
      confirmLabel: 'Install',
    );
    if (ok) await controller.install();
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.candidate});

  final UpdateCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final notes = displayNotes(candidate.notes);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.background,
        borderRadius: BorderRadius.circular(AppMetrics.controlRadius),
        border: Border.all(color: p.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Version ${candidate.version}  ·  ${formatSize(candidate.size)}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.text,
            ),
          ),
          if (!candidate.signed &&
              candidate.platform.os == UpdateOs.android) ...[
            const SizedBox(height: 6),
            Text(
              'The release information is not signed yet. Android will still '
              'only accept a package signed with the same key as Notes.',
              style: TextStyle(fontSize: 12, height: 1.4, color: p.textMuted),
            ),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'What is new',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.textMuted,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              notes,
              style: TextStyle(fontSize: 13, height: 1.4, color: p.text),
            ),
          ],
        ],
      ),
    );
  }
}
