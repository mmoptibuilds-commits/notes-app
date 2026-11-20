import '../../app.dart';
import '../../sync/peers.dart';
import '../../sync/sync_service.dart';
import '../material.dart';
import '../shortcuts/shortcut_guards.dart';
import '../theme/app_theme.dart';
import 'pair_screen.dart';

/// Paired devices, sync status and pairing.
class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final sync = app.sync;
    return backOnEscape(
      child: Scaffold(
        appBar: AppBar(title: const Text('Sync')),
        body: sync == null
            ? const Center(child: Text('Sync is not available.'))
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      sync,
                      app.notes.changes,
                      app.settings,
                    ]),
                    builder: (context, _) => _Body(sync: sync),
                  ),
                ),
              ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.sync});

  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final settings = AppScope.of(context).settings;
    final peers = sync.peers.list();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
      children: [
        _Card(
          children: [
            ListTile(
              title: const Text('This device'),
              subtitle: Text(settings.deviceName),
              trailing: IconButton(
                tooltip: 'Rename this device',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () async {
                  final v = await _ask(
                    context,
                    'Name this device',
                    settings.deviceName,
                  );
                  if (v != null && v.trim().isNotEmpty) {
                    settings.deviceName = v.trim();
                  }
                },
              ),
            ),
            _Addresses(sync: sync),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: peers.isEmpty || sync.syncing
                    ? null
                    : () => _syncAll(context),
                icon: sync.syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(sync.syncing ? 'Syncing…' : 'Sync now'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: peers.length >= maxDevices - 1
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const PairScreen(),
                        ),
                      ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Pair a device'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Text(
            peers.isEmpty
                ? 'No paired devices'
                : 'Paired devices (${peers.length} of ${maxDevices - 1})',
            style: TextStyle(
              color: p.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (peers.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Pair another of your devices to keep your notes in step. They '
              'sync directly with each other, with no account and no server.',
              style: TextStyle(color: p.textMuted, fontSize: 13, height: 1.4),
            ),
          )
        else
          _Card(
            children: [
              for (var i = 0; i < peers.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _PeerTile(peer: peers[i], sync: sync),
              ],
            ],
          ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Devices sync when both are open at the same time on the same '
            'network, or both on Tailscale. A device that is off or away '
            'catches up the next time they meet. Changes are kept safely '
            'until then, and nothing is ever sent through a third party.',
            style: TextStyle(color: p.textFaint, fontSize: 12, height: 1.45),
          ),
        ),
      ],
    );
  }

  Future<void> _syncAll(BuildContext context) async {
    final m = ScaffoldMessenger.of(context);
    final result = await sync.syncAll();
    final failed = sync.peers
        .list()
        .where((p) => sync.lastError[p.id] != null)
        .length;
    final changed = result.values.fold<int>(
      0,
      (a, o) => a + o.created + o.updated,
    );
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: Text(
          failed > 0 && result.isEmpty
              ? 'Could not reach your other devices.'
              : changed > 0
              ? 'Synced. $changed ${changed == 1 ? 'change' : 'changes'} received.'
              : 'Up to date.',
        ),
      ),
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

class _Addresses extends StatelessWidget {
  const _Addresses({required this.sync});
  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return FutureBuilder<List<String>>(
      future: sync.addresses(),
      builder: (context, snap) {
        final list = snap.data ?? const [];
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            !sync.running
                ? 'Sync is off.'
                : list.isEmpty
                ? 'No network connection. Changes are kept until one is available.'
                : 'Reachable at ${list.map(describeEndpoint).join(', ')}',
            style: TextStyle(color: p.textFaint, fontSize: 12),
          ),
        );
      },
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.sync});

  final Peer peer;
  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final syncing = sync.syncing && sync.currentPeerName == peer.name;
    final error = sync.lastError[peer.id] ?? peer.lastError;
    final pending = sync.peers.pendingFor(peer.id);
    final String status;
    var isError = false;
    if (syncing) {
      status = 'Syncing…';
    } else if (error != null) {
      status = error;
      isError = true;
    } else if (peer.lastSyncAt != null) {
      status =
          'Synced ${_ago(DateTime.fromMillisecondsSinceEpoch(peer.lastSyncAt!))}'
          '${pending > 0 ? ' · $pending waiting' : ''}';
    } else {
      status = 'Not synced yet${pending > 0 ? ' · $pending waiting' : ''}';
    }
    return ListTile(
      leading: Icon(Icons.devices_rounded, color: p.textMuted),
      title: Text(peer.name),
      subtitle: Text(
        status,
        style: TextStyle(color: isError ? p.danger : p.textMuted, fontSize: 12),
        maxLines: 2,
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Device options',
        onSelected: (v) async {
          switch (v) {
            case 'sync':
              await sync.syncPeer(peer.id);
            case 'rename':
              final n = await _ask(context, 'Rename device', peer.name);
              if (n != null && n.trim().isNotEmpty) {
                sync.renamePeer(peer.id, n.trim());
              }
            case 'remove':
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text('Remove ${peer.name}?'),
                  content: const Text(
                    'It will stop syncing with this device. Notes already '
                    'exchanged stay on both. To sync again, pair them again.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: Text(
                        'Remove',
                        style: TextStyle(color: AppPalette.of(c).danger),
                      ),
                    ),
                  ],
                ),
              );
              if (ok == true) sync.removePeer(peer.id);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'sync', child: Text('Sync now')),
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'remove', child: Text('Remove')),
        ],
      ),
    );
  }
}

Future<String?> _ask(BuildContext context, String title, String initial) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, c.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  return '${t.day}/${t.month}/${t.year}';
}
