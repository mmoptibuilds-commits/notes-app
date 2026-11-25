import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/models.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';

import '../../tool/cloud_test_reset.dart';
import 'cloud_manual_smoke.dart';
import 'cloud_scenario.dart' show TestCloudLogin;

/// Checks the Linux runner of the manual smoke test against a simulated phone
/// (a second app database acting like the person following the checklist).
void main() {
  final configured = Platform.environment['CLOUD_LIVE_URL'];
  final worker = configured == null ? null : Uri.tryParse(configured);

  test(
    'manual smoke runner completes with a simulated phone',
    () async {
      await resetCloudTestLibrary(worker!);
      final lines = <String>[];
      await Future.wait([
        runManualSmokeLinux(
          worker,
          wait: const Duration(minutes: 3),
          say: (line) {
            lines.add(line);
            // ignore: avoid_print
            print('SMOKE $line');
          },
        ),
        _simulatedPhone(worker),
      ]);
      expect(lines.any((l) => l.startsWith('PASS')), isTrue);
      expect(lines.any((l) => l.startsWith('LAN sync inactive')), isTrue);
    },
    skip: worker == null
        ? 'Set CLOUD_LIVE_URL to run against the isolated test Worker.'
        : false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<void> _simulatedPhone(Uri worker) async {
  final dir = await Directory.systemTemp.createTemp('notes-cloud-sim-phone-');
  final sessions = MemoryCloudSessionStore();
  final services = await bootstrap(dataDir: dir.path);
  await services.cloud?.stop();
  final api = HttpCloudApi(baseUrl: worker, sessions: sessions);
  final cloud = CloudService(
    repo: services.notes,
    api: api,
    sessions: sessions,
    dataDir: dir.path,
    deviceName: 'Simulated phone',
    loginLauncher: TestCloudLogin(worker),
    unavailable: false,
  );
  final repo = services.notes;
  String body(String text) => jsonEncode([
    {'insert': '$text\n'},
  ]);
  Future<void> until(bool Function() done) async {
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(end)) {
      await cloud.syncNow();
      if (done()) return;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('simulated phone timed out');
  }

  try {
    await cloud.signIn();
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (true) {
      try {
        if ((await api.library()).state == 'ready') break;
      } on CloudApiException {
        // No library yet: Linux has not uploaded.
      }
      if (DateTime.now().isAfter(end)) throw StateError('library never ready');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await cloud.join(await cloud.inspectForJoin());
    await cloud.syncNow();
    repo.createNote(
      title: 'from the phone $smokeFromPhone',
      body: body('typed on mobile data'),
    );
    await cloud.syncNow();
    await until(
      () => repo
          .listNotes(scope: NoteScope.active)
          .any((n) => n.title == smokeLinuxReply),
    );
    repo.createNote(title: smokePhoneSawReply, body: body('saw the reply'));
    await cloud.syncNow();
    await cloud.signOut();
  } finally {
    await cloud.stop();
    cloud.dispose();
    api.close();
    services.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}
