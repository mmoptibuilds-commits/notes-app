import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/live/cloud_latency.dart';
import '../test/live/cloud_scenario.dart' show CloudScenarioRole;

/// Automatic-sync latency between Linux (role L) and the phone (role A).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const role = String.fromEnvironment('CLOUD_ROLE');
  const url = String.fromEnvironment('NOTES_CLOUD_URL');

  testWidgets('cloud sync latency ($role)', (tester) async {
    if (url.isEmpty) throw StateError('NOTES_CLOUD_URL is required.');
    final parsed = switch (role) {
      'L' => CloudScenarioRole.linux,
      'A' => CloudScenarioRole.android,
      _ => throw StateError('CLOUD_ROLE must be L or A.'),
    };
    await runCloudLatency(parsed, Uri.parse(url));
  }, timeout: const Timeout(Duration(minutes: 60)));
}
