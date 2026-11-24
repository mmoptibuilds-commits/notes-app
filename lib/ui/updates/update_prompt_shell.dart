import '../../update/installer.dart';
import '../../update/update_controller.dart';
import '../../update/update_status.dart';
import '../material.dart';
import '../theme/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/touch.dart';

/// Adds non-blocking update prompts above the current root screen. The banner
/// takes its own space so it never covers the editor or captures its input.
class UpdatePromptShell extends StatelessWidget {
  const UpdatePromptShell({
    super.key,
    required this.controller,
    required this.child,
  });

  final UpdateController? controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final updates = controller;
    if (updates == null) return child;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final outcome = updates.lastOutcome;
        final status = updates.status;
        final ready = status is UpdateReadyToInstall ? status : null;
        final candidate = ready?.candidate;
        if (outcome == null &&
            (candidate == null || !updates.shouldShowReadyPrompt)) {
          return child;
        }
        return Column(
          children: [
            SafeArea(
              bottom: false,
              child: outcome != null
                  ? _OutcomeBanner(
                      message: outcome.message,
                      updated: outcome.updated,
                      onDismiss: updates.dismissOutcome,
                    )
                  : _ReadyBanner(
                      controller: updates,
                      candidate: candidate!,
                      retryMessage: ready!.message,
                      retry: ready.retry,
                    ),
            ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReadyBanner extends StatelessWidget {
  const _ReadyBanner({
    required this.controller,
    required this.candidate,
    required this.retryMessage,
    required this.retry,
  });

  final UpdateController controller;
  final UpdateCandidate candidate;
  final String? retryMessage;
  final bool retry;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final android = candidate.platform.os == UpdateOs.android;
    return _BannerSurface(
      icon: Icons.system_update_alt_rounded,
      iconColor: palette.accent,
      label: 'Update ready',
      message: retry
          ? retryMessage!
          : 'Notes ${candidate.version} has been downloaded and verified.',
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: Size(64, hitSize(context)),
            visualDensity: VisualDensity.standard,
          ),
          onPressed: () => _confirmInstall(context, android),
          child: Text(retry ? 'Retry' : 'Install now'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: Size(64, hitSize(context)),
            visualDensity: VisualDensity.standard,
          ),
          onPressed: controller.snoozeReadyPrompt,
          child: const Text('Later'),
        ),
      ],
    );
  }

  Future<void> _confirmInstall(BuildContext context, bool android) async {
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

class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({
    required this.message,
    required this.updated,
    required this.onDismiss,
  });

  final String message;
  final bool updated;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return _BannerSurface(
      icon: updated ? Icons.check_circle_outline_rounded : Icons.info_outline,
      iconColor: updated ? palette.accent : palette.textMuted,
      label: updated ? 'Notes updated' : 'Update status',
      message: message,
      actions: [
        TextButton.icon(
          style: TextButton.styleFrom(
            minimumSize: Size(64, hitSize(context)),
            visualDensity: VisualDensity.standard,
          ),
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded, size: 18),
          label: const Text('Dismiss'),
        ),
      ],
    );
  }
}

class _BannerSurface extends StatelessWidget {
  const _BannerSurface({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.message,
    required this.actions,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Material(
      color: palette.raised,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.cardBorder)),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final status = Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, color: iconColor, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Semantics(
                          container: true,
                          liveRegion: true,
                          label: '$label. $message',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: TextStyle(
                                  color: palette.text,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                message,
                                style: TextStyle(
                                  color: palette.textMuted,
                                  fontSize: 12.5,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                  // Narrow windows or large text: actions go below the copy
                  // so the message keeps the full width.
                  final narrow =
                      constraints.maxWidth <
                      520 * MediaQuery.textScalerOf(context).scale(1);
                  if (narrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        status,
                        const SizedBox(height: 6),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: Wrap(spacing: 4, children: actions),
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: status),
                      const SizedBox(width: 12),
                      Wrap(spacing: 4, children: actions),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
