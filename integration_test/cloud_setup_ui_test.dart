import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/live/cloud_scenario.dart' show CloudScenarioRole;
import '../test/live/cloud_setup_ui_scenario.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const role = String.fromEnvironment('CLOUD_ROLE');
  const configuredUrl = String.fromEnvironment('NOTES_CLOUD_URL');

  testWidgets('empty-library cloud setup through UI ($role)', (tester) async {
    final url = configuredUrl.isNotEmpty
        ? configuredUrl
        : Platform.environment['NOTES_CLOUD_URL'];
    if (url == null || url.isEmpty) {
      throw StateError('NOTES_CLOUD_URL is required.');
    }
    final parsedRole = switch (role) {
      'L' => CloudScenarioRole.linux,
      'A' => CloudScenarioRole.android,
      _ => throw StateError('CLOUD_ROLE must be L or A.'),
    };
    await runCloudSetupUiScenario(tester, parsedRole, Uri.parse(url));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
