import '../../app.dart';
import '../../platform/cloud_login.dart';
import '../../sync/cloud/cloud_api.dart';
import '../../sync/cloud/cloud_service.dart';
import '../../sync/cloud/cloud_sync_engine.dart';
import '../material.dart';
import '../theme/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/responsive.dart';
import '../widgets/touch.dart';

/// Private cloud sync setup, upload, join and device management.
class CloudScreen extends StatefulWidget {
  const CloudScreen({super.key});

  @override
  State<CloudScreen> createState() => _CloudScreenState();
}

class _CloudScreenState extends State<CloudScreen> {
  CloudService get _cloud => AppScope.of(context).cloud!;
  bool _working = false;
  String? _message;
  VerifiedBackup? _backup;
  JoinReport? _report;
  Future<CloudLibraryInfo?>? _library;
  Future<Map<String, Object?>>? _devices;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  void _refresh() {
    if (!mounted) return;
    final cloud = _cloud;
    setState(() {
      _library = _loadLibrary(cloud);
      _devices = cloud.devices();
    });
  }

  Future<CloudLibraryInfo?> _loadLibrary(CloudService cloud) async {
    try {
      return await cloud.libraryInfo();
    } on CloudApiException catch (e) {
      if (e.kind == CloudErrorKind.notFound) return null;
      rethrow;
    }
  }

  Future<void> _act(Future<void> Function() action, {String? success}) async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await action();
      if (!mounted) return;
      setState(() => _message = success);
      _refresh();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _friendlyError(Object error) {
    if (error is CloudLoginCancelled) return 'Sign-in was cancelled.';
    if (error is CloudLoginTimeout) {
      return 'Sign-in timed out. Try again when you are ready.';
    }
    if (error.toString().contains('Sign-in is unavailable on this platform')) {
      return 'No browser is available. Open Notes on a supported device.';
    }
    if (error is UnsupportedError ||
        error.toString().contains('unavailable on this platform')) {
      return 'No browser is available. Open Notes on a supported device.';
    }
    if (error is CloudApiException) {
      return switch (error.kind) {
        CloudErrorKind.unauthorized =>
          'This server is private. Sign in with your own Google account.',
        CloudErrorKind.network =>
          'You appear to be offline. Check your connection and try again.',
        _ =>
          'Cloud sync could not finish. Check your connection and try again.',
      };
    }
    return 'Cloud sync could not finish. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    final cloud = _cloud;
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud sync')),
      body: ListenableBuilder(
        listenable: cloud,
        builder: (context, _) => BoundedPage(
          child: ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 32),
            children: [
              _stateContent(context, cloud),
              if (_message != null) ...[
                const SizedBox(height: 12),
                _Notice(text: _message!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _stateContent(BuildContext context, CloudService cloud) {
    final status = cloud.status;
    if (status.phase == CloudPhase.unavailable) {
      return const _Card(
        children: [Text('Cloud sync is unavailable in this build.')],
      );
    }
    if (status.phase == CloudPhase.off ||
        status.phase == CloudPhase.signedOut) {
      return _signedOut(context, cloud);
    }
    if (status.phase == CloudPhase.uploading) return _uploading(context, cloud);
    if (status.phase == CloudPhase.ready || status.phase == CloudPhase.paused) {
      return _ready(context, cloud);
    }
    return FutureBuilder<CloudLibraryInfo?>(
      future: _library,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Card(
            children: [
              const Text('Could not check the cloud library.'),
              const SizedBox(height: 8),
              _button('Try again', () => _refresh()),
            ],
          );
        }
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasError) {
          return const _Card(
            children: [
              LinearProgressIndicator(),
              SizedBox(height: 12),
              Text('Checking cloud status…'),
            ],
          );
        }
        final library = snapshot.data;
        if (library == null) return _upload(context, cloud);
        if (library.state == 'uploading') return _upload(context, cloud);
        return _join(context, cloud);
      },
    );
  }

  Widget _signedOut(BuildContext context, CloudService cloud) => _Card(
    children: [
      Text(
        'Your notes stay on this device until you turn cloud sync on.',
        style: _titleStyle(context),
      ),
      const SizedBox(height: 8),
      const Text(
        'Cloud sync stores a readable copy on a private server you control: a Cloudflare Worker and a Neon database. It is not end-to-end encrypted. Only your own Google account can sign in. LAN sync keeps working.',
      ),
      const SizedBox(height: 16),
      _button(
        _working ? 'Waiting for browser…' : 'Sign in with Google',
        _working
            ? null
            : () async {
                setState(() {
                  _working = true;
                  _message = null;
                });
                try {
                  await cloud.signIn();
                  if (mounted) {
                    setState(() => _message = 'Signed in.');
                    _refresh();
                  }
                } on Object catch (e) {
                  if (mounted) setState(() => _message = _friendlyError(e));
                } finally {
                  if (mounted) setState(() => _working = false);
                }
              },
        icon: _working ? null : Icons.open_in_browser_rounded,
      ),
      if (_working)
        TextButton(
          onPressed: () {
            cloud.loginLauncher?.cancel();
            setState(() {
              _working = false;
              _message = 'Sign-in was cancelled.';
            });
          },
          child: const Text('Cancel'),
        ),
    ],
  );

  Widget _upload(BuildContext context, CloudService cloud) {
    final summary = cloud.localSummary();
    final backup = _backup;
    return _Card(
      children: [
        Text('Upload this library', style: _titleStyle(context)),
        const SizedBox(height: 8),
        Text(
          '${_plural(summary['notes'] ?? 0, 'note')} · ${_plural(summary['folders'] ?? 0, 'folder')} · ${_plural(summary['images'] ?? 0, 'image')} · ${_size(summary['bytes'] ?? 0)}',
        ),
        const SizedBox(height: 8),
        const Text(
          'This makes a one-time copy. The server will hold a readable copy of your notes.',
        ),
        const SizedBox(height: 16),
        Text('1. Verified backup', style: _titleStyle(context)),
        const SizedBox(height: 6),
        _button(
          _working && backup == null
              ? 'Creating backup…'
              : 'Create verified backup',
          backup != null || _working
              ? null
              : () => _act(() async {
                  final b = await cloud.createVerifiedBackup();
                  setState(() => _backup = b);
                }, success: 'Backup verified.'),
          icon: Icons.verified_outlined,
        ),
        if (backup != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Verified: ${_plural(backup.notes, 'note')}, ${_plural(backup.folders, 'folder')}, ${_plural(backup.attachments, 'image')}\n${backup.path}',
            ),
          ),
        const SizedBox(height: 16),
        Text('2. Upload', style: _titleStyle(context)),
        const SizedBox(height: 6),
        _button(
          'Upload this library',
          backup == null || _working
              ? null
              : () async {
                  final ok = await confirmDialog(
                    context,
                    title: 'Upload this library?',
                    message:
                        'The server will store a readable copy of these notes. A verified backup is ready at ${backup.path}.',
                    confirmLabel: 'Upload',
                  );
                  if (ok) {
                    await _act(
                      () => cloud.uploadLibrary(backup),
                      success: 'Upload complete.',
                    );
                  }
                },
          icon: Icons.cloud_upload_outlined,
        ),
        if (_working) _progress(cloud.status.uploadProgress),
      ],
    );
  }

  Widget _uploading(BuildContext context, CloudService cloud) => _Card(
    children: [
      Text('Upload this library', style: _titleStyle(context)),
      const SizedBox(height: 8),
      const Text(
        'Upload is in progress. It can resume after you leave this screen.',
      ),
      _progress(cloud.status.uploadProgress),
      _button(
        'Resume upload',
        _working
            ? null
            : () async {
                final b = _backup ?? await cloud.createVerifiedBackup();
                setState(() => _backup = b);
                await _act(
                  () => cloud.uploadLibrary(b),
                  success: 'Upload complete.',
                );
              },
      ),
    ],
  );

  Widget _join(BuildContext context, CloudService cloud) {
    final r = _report;
    final empty =
        (cloud.localSummary()['notes'] ?? 0) == 0 &&
        (cloud.localSummary()['folders'] ?? 0) == 0;
    return _Card(
      children: [
        Text('Check this device', style: _titleStyle(context)),
        const SizedBox(height: 8),
        const Text(
          'This read-only check compares counts. It does not change either copy.',
        ),
        const SizedBox(height: 12),
        _button(
          _working && r == null ? 'Checking…' : 'Check this device',
          _working
              ? null
              : () => _act(() async {
                  _report = await cloud.inspectForJoin();
                }, success: 'Check complete.'),
          icon: Icons.fact_check_outlined,
        ),
        if (r != null) ...[
          const SizedBox(height: 12),
          Text(
            'Identical: ${r.identical}\nOnly on this device: ${r.onlyHere}\nOnly on the server: ${r.onlyThere}\nDifferent: ${r.differing}\nAttachments missing: ${r.missingAttachments}',
            semanticsLabel: 'Join check counts',
          ),
          if (r.exact || empty) ...[
            const SizedBox(height: 12),
            _button(
              'Join',
              _working
                  ? null
                  : () async {
                      final ok = await confirmDialog(
                        context,
                        title: 'Join this device?',
                        message: 'This device will join the cloud library. Continue?',
                        confirmLabel: 'Join',
                      );
                      if (ok) {
                        await _act(
                          () => cloud.join(r),
                          success: 'This device joined.',
                        );
                      }
                    },
            ),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'Both copies are untouched. Sync over LAN first, then check again.',
              ),
            ),
        ],
      ],
    );
  }

  Widget _ready(BuildContext context, CloudService cloud) {
    final s = cloud.status;
    final state = s.phase == CloudPhase.paused
        ? 'Cloud sync is paused'
        : s.syncing
        ? 'Syncing'
        : s.needsAttention
        ? 'Needs attention'
        : s.lastError != null
        ? 'Could not sync. Check your connection.'
        : 'Up to date';
    return _Card(
      children: [
        Text(
          state,
          style: _titleStyle(context).copyWith(
            color: s.needsAttention ? AppPalette.of(context).danger : null,
          ),
        ),
        if (s.lastSyncAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Last synced ${_date(s.lastSyncAt!)}'),
          ),
        Text(
          '${s.pendingRows} pending ${s.pendingRows == 1 ? 'change' : 'changes'}',
        ),
        const SizedBox(height: 10),
        _button(
          s.syncing ? 'Syncing…' : 'Sync now',
          _working || s.syncing
              ? null
              : () => _act(cloud.syncNow, success: 'Up to date.'),
          icon: Icons.sync_rounded,
        ),
        if (s.syncing) _progress(s.uploadProgress),
        const Divider(height: 28),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sync this device with the cloud'),
          subtitle: const Text(
            'LAN auto-sync is paused while cloud sync is on. Manual LAN sync still works.',
          ),
          value: s.phase != CloudPhase.paused && s.phase != CloudPhase.off,
          onChanged: _working ? null : (v) => _act(() => cloud.setEnabled(v)),
        ),
        const Divider(height: 28),
        Text('Devices', style: _titleStyle(context)),
        FutureBuilder<Map<String, Object?>>(
          future: _devices,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Text('Could not load devices. Try again later.');
            }
            final rows = snap.data?['devices'];
            if (rows is! List || rows.isEmpty) {
              return const Text('No other devices yet.');
            }
            return Column(
              children: [
                for (final item in rows)
                  if (item is Map)
                    _deviceRow(context, cloud, item.cast<String, Object?>()),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        _button(
          'Sign out of this device',
          _working
              ? null
              : () async {
                  final ok = await confirmDialog(
                    context,
                    title: 'Sign out?',
                    message: 'Cloud sync will stop on this device. Your local notes stay here.',
                    confirmLabel: 'Sign out',
                  );
                  if (ok) await _act(cloud.signOut, success: 'Signed out.');
                },
          destructive: true,
        ),
      ],
    );
  }

  Widget _deviceRow(
    BuildContext context,
    CloudService cloud,
    Map<String, Object?> d,
  ) {
    final id = d['id']?.toString() ?? '';
    final name = d['name']?.toString() ?? 'Device';
    final seen = d['lastSeen']?.toString();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(name),
      subtitle: Text(seen == null ? 'Last seen unknown' : 'Last seen $seen'),
      trailing: IconButton(
        tooltip: 'Revoke $name',
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: _working
            ? null
            : () async {
                final ok = await confirmDialog(
                  context,
                  title: 'Revoke this device?',
                  message: '$name will no longer be able to sync.',
                  confirmLabel: 'Revoke',
                  destructive: true,
                );
                if (ok) {
                  await _act(
                    () => cloud.revokeDevice(id),
                    success: 'Device revoked.',
                  );
                }
              },
      ),
    );
  }

  Widget _progress(CloudSyncProgress p) {
    final value = p.total <= 0 ? null : (p.uploaded / p.total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: value),
          if (p.total > 0) Text('${p.uploaded} of ${p.total}'),
        ],
      ),
    );
  }

  Widget _button(
    String label,
    VoidCallback? onPressed, {
    IconData? icon,
    bool destructive = false,
  }) {
    final p = AppPalette.of(context);
    final style = FilledButton.styleFrom(
      minimumSize: touchButtonMinimumSize(context),
      visualDensity: touchVisualDensity(context),
      backgroundColor: destructive ? p.danger : null,
    );
    if (icon == null) {
      return FilledButton(
        onPressed: onPressed,
        style: style,
        child: Text(label),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon),
      label: Text(label),
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      text,
      style: TextStyle(color: AppPalette.of(context).textMuted),
    ),
  );
}

TextStyle _titleStyle(BuildContext context) => TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w600,
  color: AppPalette.of(context).text,
);
String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
String _date(DateTime value) {
  final local = value.toLocal();
  const months = [
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
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${months[local.month - 1]} ${local.day}, $hour:$minute $period';
}

String _plural(int n, String noun) => '$n ${n == 1 ? noun : '${noun}s'}';
