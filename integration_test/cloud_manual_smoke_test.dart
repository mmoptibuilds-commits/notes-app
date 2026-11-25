import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/live/cloud_manual_smoke.dart';

/// Linux half of the manual smoke test: tool/cloud_manual_smoke.md.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('NOTES_CLOUD_URL');
  const phoneIp = String.fromEnvironment('PHONE_LAN_IP');

  test('manual mobile-data smoke test (Linux side)', () async {
    if (url.isEmpty) throw StateError('NOTES_CLOUD_URL is required.');
    await runManualSmokeLinux(
      Uri.parse(url),
      phoneLanIp: phoneIp.isEmpty ? null : phoneIp,
    );
  }, timeout: const Timeout(Duration(minutes: 90)));
}
