import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:notes/data/models.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';

import 'cloud_scenario.dart' show CloudScenarioRole, TestCloudLogin;
import 'toggling_proxy.dart';

/// Measures how long automatic cloud sync takes between two devices, with no
/// manual "Sync now". Two roles pass a note back and forth ("hops"); the sender
/// embeds its wall clock in the note and the receiver prints one `LAT` line
/// with its own arrival time. tool/cloud_latency_report.dart turns the lines
/// into timings (correcting for the phone/Linux clock offset).
///
/// Hop kinds:
///  * save       save on one device, nothing else (debounce + poll)
///  * poll       save then push at once (isolates the receiver's polling)
///  * resume     receiver is paused (Android: sync stopped) and then resumed
///  * pauseflush sender saves and goes to the background right away
///  * reconnect  sender saves while offline for [_offlineHold], then reconnects
Future<void> runCloudLatency(
  CloudScenarioRole role,
  Uri worker, {
  bool androidBehaviour = false,
}) async {
  final isLinux = role == CloudScenarioRole.linux;
  final me = isLinux ? 'L' : 'A';
  final dataDir = await Directory.systemTemp.createTemp('notes-cloud-latency-');
  final sessions = MemoryCloudSessionStore();
  AppServices? services;
  CloudService? cloud;
  HttpCloudApi? api;
  TogglingProxy? proxy;
  void say(String line) {
    // ignore: avoid_print
    print(line);
  }

  try {
    services = await bootstrap(dataDir: dataDir.path);
    await services.cloud?.stop();
    final lan = services.sync;
    if (lan != null && (lan.running || lan.peers.list().isNotEmpty)) {
      throw StateError(
        'LAN sync is active; the cloud path would not be isolated',
      );
    }
    proxy = await TogglingProxy.start(worker);
    final httpApi = HttpCloudApi(baseUrl: proxy.url, sessions: sessions);
    api = httpApi;
    final service = CloudService(
      repo: services.notes,
      api: httpApi,
      sessions: sessions,
      dataDir: dataDir.path,
      deviceName: isLinux ? 'Linux latency' : 'Android latency',
      loginLauncher: TestCloudLogin(proxy.url),
      unavailable: false,
      platformIsAndroid: androidBehaviour ? () => true : null,
    );
    cloud = service;
    final repo = services.notes;
    final live = proxy;

    Future<void> until(
      Duration timeout,
      FutureOr<bool> Function() done, {
      Duration every = const Duration(milliseconds: 100),
      required String what,
    }) async {
      final end = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(end)) {
        if (await done()) return;
        await Future<void>.delayed(every);
      }
      throw StateError('Timed out waiting for $what');
    }

    NoteRecord? find(String prefix) {
      for (final n in repo.listNotes(scope: NoteScope.active)) {
        if (n.title.startsWith(prefix)) return repo.getRecord(n.id);
      }
      return null;
    }

    int now() => DateTime.now().millisecondsSinceEpoch;
    String body(int saved, int hold) => jsonEncode([
      {'insert': 'saved=$saved hold=$hold\n'},
    ]);
    ({int saved, int hold}) parse(NoteRecord r) {
      final m = RegExp(r'saved=(\d+) hold=(\d+)').firstMatch(r.body)!;
      return (saved: int.parse(m.group(1)!), hold: int.parse(m.group(2)!));
    }

    // ---- setup (manual sync is fine here; nothing is measured yet) ----
    await service.signIn();
    if (isLinux) {
      repo.createNote(
        title: 'Latency base',
        body: jsonEncode([
          {'insert': 'synthetic\n'},
        ]),
      );
      await service.uploadLibrary(await service.createVerifiedBackup());
    } else {
      await until(
        const Duration(minutes: 20),
        () async {
          try {
            return (await httpApi.library()).state == 'ready';
          } on CloudApiException {
            return false;
          }
        },
        every: const Duration(seconds: 1),
        what: 'the Linux library',
      );
      await service.join(await service.inspectForJoin());
      await service.syncNow();
    }
    await service.setEnabled(true); // starts the automatic timers
    say('LATSETUP role=$me running=${service.active}');
    if (!isLinux) {
      repo.createNote(title: 'LAT-0-A', body: body(now(), 0));
      await service.syncNow();
    } else {
      await until(
        const Duration(minutes: 20),
        () async {
          await service.syncNow();
          return find('LAT-0-A') != null;
        },
        every: const Duration(seconds: 1),
        what: 'the Android role',
      );
    }

    // ---- hops ----
    const hops = <(int, String)>[
      (1, 'save'),
      (2, 'save'),
      (3, 'save'),
      (4, 'save'),
      (5, 'save'),
      (6, 'save'),
      (7, 'poll'),
      (8, 'poll'),
      (9, 'poll'),
      (10, 'poll'),
      (11, 'resume'),
      (12, 'pauseflush'),
      (13, 'resume'),
      (14, 'pauseflush'),
      (15, 'reconnect'),
      (16, 'reconnect'),
    ];
    const offlineHold = Duration(seconds: 100);
    const pauseHold = Duration(seconds: 60);
    const backgroundHold = Duration(seconds: 45);
    for (final (k, kind) in hops) {
      final sendsThis = k.isOdd == isLinux;
      final prefix = 'LAT-$k-';
      if (sendsThis) {
        final jitter = kind == 'save' || kind == 'poll'
            ? Duration(milliseconds: Random(k).nextInt(25000))
            : kind == 'resume'
            ? const Duration(seconds: 5)
            : const Duration(seconds: 2);
        await Future<void>.delayed(jitter);
        switch (kind) {
          case 'save':
          case 'resume':
            repo.createNote(title: '$prefix$kind', body: body(now(), 0));
            if (kind == 'resume') await service.syncNow();
          case 'poll':
            repo.createNote(title: '$prefix$kind', body: body(now(), 0));
            await service.syncNow();
          case 'pauseflush':
            repo.createNote(title: '$prefix$kind', body: body(now(), 0));
            await service.lifecycleChanged(resumed: false, paused: true);
            await Future<void>.delayed(backgroundHold);
            await service.lifecycleChanged(resumed: true, paused: false);
          case 'reconnect':
            live.online = false;
            final saved = now();
            repo.createNote(
              title: '$prefix$kind',
              body: body(saved, offlineHold.inMilliseconds),
            );
            await Future<void>.delayed(offlineHold);
            live.online = true;
        }
        say('LATSENT k=$k kind=$kind from=$me at=${now()}');
      } else {
        var reference = 0; // receiver-clock reference for resume hops
        if (kind == 'resume') {
          await service.syncNow();
          await service.lifecycleChanged(resumed: false, paused: true);
          await Future<void>.delayed(pauseHold);
          reference = now();
          await service.lifecycleChanged(resumed: true, paused: false);
        }
        NoteRecord? got;
        var timedOut = false;
        try {
          await until(const Duration(minutes: 6), () {
            got = find(prefix);
            return got != null;
          }, what: 'hop $k ($kind)');
        } on StateError {
          timedOut = true;
        }
        final arrival = now();
        if (timedOut || got == null) {
          say('LAT k=$k kind=$kind to=$me timedOut=true');
        } else {
          final p = parse(got!);
          final local = kind == 'resume' ? arrival - reference : -1;
          final valid = kind != 'resume' || p.saved + 3000 < reference;
          say(
            'LAT k=$k kind=$kind to=$me arrival=$arrival saved=${p.saved} '
            'hold=${p.hold} local=$local valid=$valid timedOut=false',
          );
        }
      }
    }
    await service.signOut();
    say('LATDONE role=$me');
  } finally {
    final active = cloud;
    if (active != null) {
      await active.stop();
      active.dispose();
    }
    api?.close();
    await proxy?.close();
    services?.close();
    if (dataDir.existsSync()) await dataDir.delete(recursive: true);
  }
}
