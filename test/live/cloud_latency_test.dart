import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/cloud_test_reset.dart';
import 'cloud_latency.dart';
import 'cloud_scenario.dart' show CloudScenarioRole;

/// Both latency roles in one process (the "phone" uses Android lifecycle
/// behaviour). Quick harness check; the real numbers come from
/// tool/cloud_latency_test.sh with a phone.
void main() {
  final configured = Platform.environment['CLOUD_LIVE_URL'];
  final worker = configured == null ? null : Uri.tryParse(configured);

  test(
    'two-role cloud latency run',
    () async {
      await resetCloudTestLibrary(worker!);
      await Future.wait([
        runCloudLatency(CloudScenarioRole.linux, worker),
        runCloudLatency(
          CloudScenarioRole.android,
          worker,
          androidBehaviour: true,
        ),
      ]);
    },
    skip: worker == null
        ? 'Set CLOUD_LIVE_URL to run against the isolated test Worker.'
        : false,
    timeout: const Timeout(Duration(minutes: 60)),
  );
}
