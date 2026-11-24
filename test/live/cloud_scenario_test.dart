import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'cloud_scenario.dart';

void main() {
  final configured = Platform.environment['CLOUD_LIVE_URL'];
  final worker = configured == null ? null : Uri.tryParse(configured);

  test(
    'two-role cloud device scenario',
    () async {
      await Future.wait([
        runCloudScenario(CloudScenarioRole.linux, worker!),
        runCloudScenario(CloudScenarioRole.android, worker),
      ]);
    },
    skip: worker == null
        ? 'Set CLOUD_LIVE_URL to run against the isolated test Worker.'
        : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
