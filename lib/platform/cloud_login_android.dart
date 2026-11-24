import 'dart:async';

import 'package:flutter/services.dart';

import 'cloud_login.dart';

class AndroidCloudLoginLauncher implements CloudLoginLauncher {
  static const _channel = MethodChannel('com.mmoptibuilds.notes/cloudlogin');
  Completer<CloudLoginResult>? _pending;
  Timer? _timer;
  bool _handlerInstalled = false;

  @override
  Future<CloudLoginResult> login(
    Uri Function(String redirect) startUrl, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (_pending != null) throw StateError('A cloud login is already active');
    final pending = Completer<CloudLoginResult>();
    _pending = pending;
    if (!_handlerInstalled) {
      _channel.setMethodCallHandler(_handleCall);
      _handlerInstalled = true;
    }
    try {
      // Anything the native side kept from before this login is stale: it
      // belongs to an earlier attempt whose verifier no longer exists. Clear
      // it and ignore the value; only a callback that arrives after the
      // browser was opened can complete this login.
      await _channel.invokeMethod<String>('consumeInitialUri');
      final redirect =
          await _channel.invokeMethod<String>('redirectUri') ??
          'com.mmoptibuilds.notes:/cloud-auth';
      await _channel.invokeMethod<void>('openUrl', {
        'url': startUrl(redirect).toString(),
      });
    } catch (_) {
      if (!pending.isCompleted) {
        _finishError(Exception('Could not open the sign-in page'));
      }
    }
    _timer = Timer(timeout, () {
      if (identical(_pending, pending)) _finishError(const CloudLoginTimeout());
    });
    return pending.future;
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method == 'authUri' && call.arguments is String) {
      _receive(call.arguments as String);
    }
  }

  void _receive(String value) {
    try {
      _finish(parseCloudLoginRedirect(Uri.parse(value)));
    } catch (error) {
      _finishError(error);
    }
  }

  void _finish(CloudLoginResult result) {
    final pending = _pending;
    if (pending == null) return;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    pending.complete(result);
  }

  void _finishError(Object error) {
    final pending = _pending;
    if (pending == null) return;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    pending.completeError(error);
  }

  @override
  void cancel() => _finishError(const CloudLoginCancelled());
}
