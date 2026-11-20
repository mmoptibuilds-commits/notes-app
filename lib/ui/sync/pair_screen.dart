import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app.dart';
import '../../sync/pairing.dart';
import '../../sync/sync_service.dart';
import '../material.dart';
import '../shortcuts/shortcut_guards.dart';
import '../widgets/touch.dart';
import '../theme/app_theme.dart';

/// Pair another device: show a code for it to scan, or scan / paste its code.
class PairScreen extends StatelessWidget {
  const PairScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final canScan = Platform.isAndroid;
    return backOnEscape(
      child: DefaultTabController(
        length: canScan ? 3 : 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Pair a device'),
            bottom: TabBar(
              tabs: [
                const Tab(text: 'Show code'),
                if (canScan) const Tab(text: 'Scan code'),
                const Tab(text: 'Enter code'),
              ],
            ),
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: TabBarView(
                // Swiping would fight the camera view.
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  const _ShowCode(),
                  if (canScan) const _ScanCode(),
                  const _EnterCode(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Runs the pairing and, on success, a first sync. Returns an error message
/// or null.
Future<String?> _pair(BuildContext context, PairingCode code) async {
  final sync = AppScope.of(context).sync!;
  final m = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  try {
    final peer = await sync.pairWith(code);
    nav.pop();
    m.showSnackBar(
      SnackBar(content: Text('Paired with ${peer.name}. Syncing…')),
    );
    unawaited(sync.syncPeer(peer.id));
    return null;
  } on PairingFailure catch (e) {
    return e.message;
  } on FormatException catch (e) {
    return e.message;
  }
}

class _ShowCode extends StatefulWidget {
  const _ShowCode();

  @override
  State<_ShowCode> createState() => _ShowCodeState();
}

class _ShowCodeState extends State<_ShowCode> {
  SyncService? _sync;
  PairingCode? _code;
  Object? _error;
  Timer? _tick;
  StreamSubscription<dynamic>? _sub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sync != null) return;
    final sync = AppScope.of(context).sync!;
    _sync = sync;
    sync
        .beginPairing()
        .then((c) {
          if (mounted) setState(() => _code = c);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
    _sub = sync.onPaired.listen((peer) {
      if (!mounted) return;
      final m = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      m.showSnackBar(SnackBar(content: Text('Paired with ${peer.name}.')));
      unawaited(sync.syncPeer(peer.id));
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    _sync?.cancelPairing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final code = _code;
    if (_error != null) {
      return Center(child: Text('Could not start pairing: $_error'));
    }
    if (code == null) return const Center(child: CircularProgressIndicator());
    final left = code.expiresAt.difference(DateTime.now());
    final text = code.encode();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'On your other device, open Notes → Sync → Pair a device, and scan '
          'this code (or enter it).',
          style: TextStyle(color: p.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            // Pure black on pure white: the most reliable thing for a camera.
            color: const Color(0xFFFFFFFF),
            child: QrImageView(
              data: text,
              size: 240,
              backgroundColor: const Color(0xFFFFFFFF),
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Color(0xFF000000),
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF000000),
              ),
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            left.isNegative
                ? 'This code has expired. Go back and start again.'
                : 'Valid for ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')} and works once.',
            style: TextStyle(
              color: left.isNegative ? p.danger : p.textMuted,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                'No camera? Copy the code and paste it on the other device.',
                style: TextStyle(color: p.textFaint, fontSize: 12),
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: touchButtonMinimumSize(context),
                visualDensity: touchVisualDensity(context),
              ),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Code copied. It works once, for five minutes.',
                      ),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy'),
            ),
          ],
        ),
      ],
    );
  }
}

class _EnterCode extends StatefulWidget {
  const _EnterCode();

  @override
  State<_EnterCode> createState() => _EnterCodeState();
}

class _EnterCodeState extends State<_EnterCode> {
  final _c = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? err;
    try {
      err = await _pair(context, PairingCode.decode(_c.text));
    } on FormatException catch (e) {
      err = e.message;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Paste the code shown on the other device (Sync → Pair a device → '
          'Show code → Copy).',
          style: TextStyle(color: p.textMuted, height: 1.4),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _c,
          minLines: 3,
          maxLines: 6,
          enabled: !_busy,
          decoration: const InputDecoration(hintText: 'notes-pair:1:…'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: touchButtonMinimumSize(context),
                visualDensity: touchVisualDensity(context),
              ),
              onPressed: _busy
                  ? null
                  : () async {
                      final d = await Clipboard.getData(Clipboard.kTextPlain);
                      if (d?.text != null) setState(() => _c.text = d!.text!);
                    },
              icon: const Icon(Icons.paste_rounded, size: 16),
              label: const Text('Paste'),
            ),
            const Spacer(),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: touchButtonMinimumSize(context),
                visualDensity: touchVisualDensity(context),
              ),
              onPressed: _busy ? null : _go,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Pair'),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: p.danger, height: 1.4),
            ),
          ),
      ],
    );
  }
}

class _ScanCode extends StatefulWidget {
  const _ScanCode();

  @override
  State<_ScanCode> createState() => _ScanCodeState();
}

class _ScanCodeState extends State<_ScanCode> {
  bool _busy = false;
  String? _error;

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_busy) return;
    final raw = cap.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstWhere((v) => v.startsWith('notes-pair:'), orElse: () => '');
    if (raw.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? err;
    try {
      err = await _pair(context, PairingCode.decode(raw));
    } on FormatException catch (e) {
      err = e.message;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Column(
      children: [
        Expanded(
          child: ClipRect(
            child: MobileScanner(
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'The camera is not available (${error.errorCode.name}). '
                    'Use "Enter code" instead.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: _busy
              ? const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text('Pairing…'),
                  ],
                )
              : Text(
                  _error ?? 'Point the camera at the code on the other device.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _error == null ? p.textMuted : p.danger,
                  ),
                ),
        ),
      ],
    );
  }
}
