class CloudLoginResult {
  const CloudLoginResult({required this.code, required this.state});
  final String code, state;
}

abstract interface class CloudLoginLauncher {
  Future<CloudLoginResult> login(
    Uri Function(String redirect) startUrl, {
    Duration timeout = const Duration(minutes: 2),
  });
}
