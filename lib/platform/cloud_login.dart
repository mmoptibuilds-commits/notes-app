import 'dart:io';

import 'cloud_login_android.dart';
import 'cloud_login_linux.dart';

class CloudLoginResult {
  const CloudLoginResult({required this.code, required this.state});
  final String code;
  final String state;
}

class CloudLoginCancelled implements Exception {
  const CloudLoginCancelled();
  @override
  String toString() => 'Cloud login was cancelled';
}

class CloudLoginTimeout implements Exception {
  const CloudLoginTimeout();
  @override
  String toString() => 'Cloud login timed out';
}

abstract class CloudLoginLauncher {
  Future<CloudLoginResult> login(
    Uri Function(String redirect) startUrl, {
    Duration timeout = const Duration(minutes: 5),
  });
  void cancel();
}

CloudLoginLauncher createCloudLoginLauncher() {
  if (Platform.isAndroid) return AndroidCloudLoginLauncher();
  if (Platform.isLinux) return LinuxCloudLoginLauncher();
  throw UnsupportedError('Cloud login is unavailable on this platform');
}

CloudLoginResult parseCloudLoginRedirect(Uri uri) {
  final error = uri.queryParameters['error'];
  if (error != null) throw Exception('Cloud sign-in failed');
  final code = uri.queryParameters['code'];
  final state = uri.queryParameters['state'];
  if (code == null || state == null || code.isEmpty || state.isEmpty) {
    throw Exception('Invalid cloud sign-in response');
  }
  return CloudLoginResult(code: code, state: state);
}
