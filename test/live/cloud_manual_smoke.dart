import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:notes/data/models.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';

import 'cloud_scenario.dart' show TestCloudLogin;

const smokeFromPhone = 'PHONE-MOBILE';
const smokeLinuxReply = 'LINUX-REPLY';
const smokePhoneSawReply = 'PHONE-SAW-REPLY';

/// Linux half of the manual mobile-data smoke test (tool/cloud_manual_smoke.md).
///
/// It needs no ADB: it uploads a synthetic library to the isolated test Worker,
/// then waits for notes typed on the phone and answers them. Output lines start
/// with `SMOKE` and never contain note text beyond the synthetic markers.
Future<void> runManualSmokeLinux(
  Uri worker, {
  String? phoneLanIp,
  Duration wait = const Duration(minutes: 40),
  void Function(String) say = _print,
}) async {
  final dataDir = await Directory.systemTemp.createTemp('notes-cloud-smoke-');
  final sessions = MemoryCloudSessionStore();
  AppServices? services;
  CloudService? cloud;
  HttpCloudApi? api;
  try {
    services = await bootstrap(dataDir: dataDir.path);
    await services.cloud?.stop(); // services.close() disposes it later
    final lan = services.sync;
    if (lan != null && (lan.running || lan.peers.list().isNotEmpty)) {
      throw StateError(
        'LAN sync is active; the cloud path would not be isolated',
      );
    }
    say('LAN sync inactive on Linux (not running, no paired peers)');
    final httpApi = HttpCloudApi(baseUrl: worker, sessions: sessions);
    api = httpApi;
    final service = CloudService(
      repo: services.notes,
      api: httpApi,
      sessions: sessions,
      dataDir: dataDir.path,
      deviceName: 'Linux smoke',
      loginLauncher: TestCloudLogin(worker),
      unavailable: false,
    );
    cloud = service;
    final repo = services.notes;

    Future<NoteRecord> waitFor(String marker) async {
      final end = DateTime.now().add(wait);
      while (DateTime.now().isBefore(end)) {
        await service.syncNow();
        for (final n in repo.listNotes(scope: NoteScope.active)) {
          final record = repo.getRecord(n.id);
          if (record != null &&
              (record.title.contains(marker) || record.body.contains(marker))) {
            return record;
          }
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      throw StateError('Timed out waiting for a note containing $marker');
    }

    await service.signIn();
    final folder = repo.createFolder('Smoke folder');
    final image = repo.putAttachment(
      Uint8List.fromList(List.generate(2048, (i) => (i * 7) % 251)),
      'image/test',
    );
    repo.createNote(
      title: 'Smoke note one',
      body: _body(['First synthetic note'], image),
      folderId: folder.id,
    );
    repo.createNote(
      title: 'Smoke note two',
      body: _body(['Second synthetic note']),
    );
    await service.uploadLibrary(await service.createVerifiedBackup());
    final library = await service.libraryInfo();
    say(
      'READY: library uploaded (${library.notes} notes, ${library.folders} '
      'folder, 1 image, state ${library.state}). Phone: sign in, join, then '
      'switch to mobile data and create a note containing $smokeFromPhone.',
    );

    final fromPhone = await waitFor(smokeFromPhone);
    say('RECEIVED $smokeFromPhone from the phone through the Worker');
    if (phoneLanIp != null) {
      final ping = await Process.run('ping', [
        '-c',
        '2',
        '-W',
        '2',
        phoneLanIp,
      ]);
      say(
        ping.exitCode == 0
            ? 'WARNING phone still answers on the LAN at $phoneLanIp; mobile data may not be the only path'
            : 'phone does not answer on the LAN at $phoneLanIp (mobile data confirmed)',
      );
    }

    repo.createNote(title: smokeLinuxReply, body: _body(['Reply from Linux']));
    await service.syncNow();
    say(
      'SENT $smokeLinuxReply. Phone: wait up to a minute for it to appear, then '
      'create a note containing $smokePhoneSawReply.',
    );
    final saw = await waitFor(smokePhoneSawReply);

    final manifest = await httpApi.manifest();
    final onServer = manifest.items.map((i) => i.id).toSet();
    if (!onServer.contains(fromPhone.id) || !onServer.contains(saw.id)) {
      throw StateError('phone notes are missing from the server manifest');
    }
    say('RECEIVED $smokePhoneSawReply; both phone notes are on the Worker');
    await service.signOut();
    say('PASS both directions through the deployed test Worker');
  } finally {
    final active = cloud;
    if (active != null) {
      await active.stop();
      active.dispose();
    }
    api?.close();
    services?.close();
    if (dataDir.existsSync()) await dataDir.delete(recursive: true);
  }
}

// ignore: avoid_print
void _print(String line) => print('SMOKE $line');

String _body(List<String> lines, [String? image]) => jsonEncode([
  for (final line in lines) {'insert': '$line\n'},
  if (image != null)
    {
      'insert': {'image': image},
    },
  {'insert': '\n'},
]);
