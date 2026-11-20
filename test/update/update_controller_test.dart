import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/bootstrap.dart';
import 'package:notes/update/download_service.dart';
import 'package:notes/update/installer.dart';
import 'package:notes/update/update_controller.dart';
import 'package:notes/update/update_http.dart';
import 'package:notes/update/update_state.dart';
import 'package:notes/update/update_status.dart';

import 'fake_http.dart';
import 'fixtures.dart';
import 'world.dart';

void main() {
  late World w;
  Future<void> setUpWorld({
    UpdatePlatform platform = linuxPlatform,
    bool pinKey = true,
  }) async {
    w = await World.create(platform: platform, pinKey: pinKey);
  }

  tearDown(() => w.dispose());

  UpdateStatus status() => w.controller.status;
  T statusIs<T extends UpdateStatus>() {
    expect(status(), isA<T>());
    return status() as T;
  }

  group('checking', () {
    test(
      'no release at all is "no stable release", never "up to date"',
      () async {
        await setUpWorld();
        w.http.on(w.apiUrl, FakeReply(404));
        await w.controller.check();
        statusIs<UpdateNoStableRelease>();
        expect(w.controller.lastSuccessfulCheck, isNotNull);
      },
    );

    test('only a pre-release published: still no stable release', () async {
      await setUpWorld();
      await w.publish(prerelease: true);
      await w.controller.check();
      statusIs<UpdateNoStableRelease>();
    });

    test(
      'a newer signed release is offered, with nothing downloaded',
      () async {
        await setUpWorld();
        await w.publish();
        await w.controller.check();
        final s = statusIs<UpdateAvailable>();
        expect(s.candidate.version, '1.0.1');
        expect(s.candidate.signed, isTrue);
        expect(s.candidate.size, w.payload.length);
        expect(s.candidate.notes, 'Fixes and small improvements.');
        // Only the API and the two small manifest files were requested.
        expect(w.http.requests.map((r) => r.url.pathSegments.last).toSet(), {
          'latest',
          'notes-manifest.json',
          'notes-manifest.json.sig',
        });
      },
    );

    test('equal version is up to date', () async {
      await setUpWorld();
      await w.publish(version: '1.0.0', build: 20261122);
      await w.controller.check();
      statusIs<UpdateUpToDate>();
    });

    test('an older release is never offered (no downgrade)', () async {
      await setUpWorld();
      w.installer.installedVersion = '1.0.5';
      await w.publish(version: '1.0.4', build: 99999999);
      await w.controller.check();
      statusIs<UpdateUpToDate>();
    });

    test(
      'same version with a higher build number is an update on Linux',
      () async {
        await setUpWorld();
        await w.publish(version: '1.0.0', build: 20261200);
        await w.controller.check();
        statusIs<UpdateAvailable>();
      },
    );

    test('1.0.10 is newer than 1.0.9', () async {
      await setUpWorld();
      w.installer.installedVersion = '1.0.9';
      await w.publish(version: '1.0.10');
      await w.controller.check();
      statusIs<UpdateAvailable>();
    });

    test('Android compares versionCode, not the version name', () async {
      await setUpWorld(platform: androidPlatform);
      w.installer.installedBuild = 20261123;
      await w.publish(version: '1.0.1', build: 20261123);
      await w.controller.check();
      statusIs<UpdateUpToDate>(); // a higher name but the same versionCode
      await w.publish(version: '1.0.2', build: 20261124);
      await w.controller.check();
      statusIs<UpdateAvailable>();
    });

    test(
      'a release without an artifact for this arch is not an update',
      () async {
        await setUpWorld();
        w.installer.platform = const UpdatePlatform(UpdateOs.linux, 'arm64');
        await w.publish();
        await w.controller.check();
        statusIs<UpdateNoPlatformRelease>();
      },
    );

    test(
      'an artifact missing from the release assets is not an update',
      () async {
        await setUpWorld();
        await w.publish(includeArtifact: false);
        await w.controller.check();
        statusIs<UpdateNoPlatformRelease>();
      },
    );

    test(
      'a release asset size that disagrees with the manifest is refused',
      () async {
        await setUpWorld();
        await w.publish(assetSizeOverride: 12345);
        await w.controller.check();
        statusIs<UpdateVerificationFailed>();
      },
    );

    test('a release without a manifest is a failure, not an update', () async {
      await setUpWorld();
      await w.publish(includeManifest: false);
      await w.controller.check();
      statusIs<UpdateFailed>();
    });

    test('no network', () async {
      await setUpWorld();
      w.http.on(w.apiUrl, FakeReply(0, error: const UpdateOfflineException()));
      await w.controller.check();
      statusIs<UpdateOffline>();
      expect(w.controller.lastSuccessfulCheck, isNull);
    });

    test('timeout is a failure, with a message', () async {
      await setUpWorld();
      w.http.on(w.apiUrl, FakeReply(200, hang: true));
      await w.controller.check();
      expect(statusIs<UpdateFailed>().message, contains('in time'));
    });

    test('rate limit reports the reset time and remembers it', () async {
      await setUpWorld();
      w.http.on(
        w.apiUrl,
        FakeReply(
          403,
          headers: {'x-ratelimit-remaining': '0', 'retry-after': '3600'},
        ),
      );
      await w.controller.check();
      final s = statusIs<UpdateRateLimited>();
      expect(s.resetAt, w.now.add(const Duration(hours: 1)));
      expect(w.store.read(UpdateKeys.retryAfter), isNotNull);
    });

    test('invalid JSON from the API is a failure', () async {
      await setUpWorld();
      w.http.on(
        w.apiUrl,
        FakeReply(
          200,
          body: [0x7b],
          headers: {'content-type': 'application/json'},
        ),
      );
      await w.controller.check();
      statusIs<UpdateFailed>();
    });

    test('a manifest served as an HTML page is refused', () async {
      await setUpWorld();
      await w.publish();
      w.http.replace(
        assetUrl('1.0.1', 'notes-manifest.json'),
        FakeReply(200, body: [60, 104], headers: {'content-type': 'text/html'}),
      );
      await w.controller.check();
      statusIs<UpdateFailed>();
    });

    test('an oversized manifest is aborted', () async {
      await setUpWorld();
      await w.publish();
      w.http.replace(
        assetUrl('1.0.1', 'notes-manifest.json'),
        FakeReply(200, body: List.filled(70 * 1024, 0x20)),
      );
      await w.controller.check();
      statusIs<UpdateFailed>();
    });

    test('a second check while one runs is ignored', () async {
      await setUpWorld();
      await w.publish();
      final a = w.controller.check();
      final b = w.controller.check();
      await Future.wait([a, b]);
      expect(w.http.count(w.apiUrl), 1);
    });
  });

  group('trust', () {
    test('a wrong signature is a verification failure', () async {
      await setUpWorld();
      await w.publish(signWith: await TestSigner.create(w.signer.keyId));
      await w.controller.check();
      statusIs<UpdateVerificationFailed>();
    });

    test('an unknown key id is a verification failure', () async {
      await setUpWorld();
      await w.publish(sigKeyId: 'someone-else');
      await w.controller.check();
      statusIs<UpdateVerificationFailed>();
    });

    test(
      'a missing signature file is a verification failure when keyed',
      () async {
        await setUpWorld();
        await w.publish(sign: false);
        await w.controller.check();
        statusIs<UpdateVerificationFailed>();
      },
    );

    test('an expired manifest is a verification failure', () async {
      await setUpWorld();
      await w.publish(expires: '2026-12-01T00:00:00Z');
      await w.controller.check();
      statusIs<UpdateVerificationFailed>();
    });

    test('a manifest whose version differs from the tag is refused', () async {
      await setUpWorld();
      await w.publish(mutate: (m) => m['version'] = '1.0.2');
      await w.controller.check();
      statusIs<UpdateVerificationFailed>();
    });

    test(
      'a replayed lower manifest is refused after a higher one was seen',
      () async {
        await setUpWorld();
        await w.publish(version: '1.0.2', build: 20261130);
        await w.controller.check();
        statusIs<UpdateAvailable>();
        expect(w.store.read(UpdateKeys.highestVersion), '1.0.2');
        await w.publish(version: '1.0.1', build: 20261123);
        await w.controller.check();
        expect(statusIs<UpdateVerificationFailed>().reason, contains('older'));
        // The same release again is fine.
        await w.publish(version: '1.0.2', build: 20261130);
        await w.controller.check();
        statusIs<UpdateAvailable>();
      },
    );

    test('an unsigned manifest never moves the replay mark', () async {
      await setUpWorld(pinKey: false);
      await w.publish(version: '9.9.9', build: 99999999, sign: false);
      await w.controller.check();
      expect(w.store.read(UpdateKeys.highestVersion), isNull);
    });

    test(
      'Linux with no pinned key: update shown but installation BLOCKED',
      () async {
        await setUpWorld(pinKey: false);
        await w.publish(sign: false);
        await w.controller.check();
        final s = statusIs<UpdateBlocked>();
        expect(s.block.kind, BlockKind.signingKeyNotProvisioned);
        expect(s.block.message, contains('not provisioned'));
        expect(s.candidate!.version, '1.0.1');
        expect(s.candidate!.signed, isFalse);
        await w.controller.download(); // refused: not an available update
        statusIs<UpdateBlocked>();
        expect(
          w.http.count(assetUrl('1.0.1', 'notes-1.0.1-linux-x64.tar.gz')),
          0,
        );
      },
    );

    test('Android with no pinned key: allowed, flagged unsigned', () async {
      await setUpWorld(platform: androidPlatform, pinKey: false);
      await w.publish(sign: false);
      await w.controller.check();
      final s = statusIs<UpdateAvailable>();
      expect(s.candidate.signed, isFalse);
    });

    test(
      'a platform block (unmanaged install) is reported with the update',
      () async {
        await setUpWorld();
        w.installer.block = const UpdateBlock(
          BlockKind.unmanagedInstall,
          'Not a managed install.',
        );
        await w.publish();
        await w.controller.check();
        expect(
          statusIs<UpdateBlocked>().block.kind,
          BlockKind.unmanagedInstall,
        );
      },
    );
  });

  group('etag cache', () {
    test('a stored etag is sent and a 304 reuses the cached release', () async {
      await setUpWorld();
      await w.publish(etag: 'W/"v1"');
      await w.controller.check();
      statusIs<UpdateAvailable>();
      expect(w.store.read(UpdateKeys.etag), 'W/"v1"');

      w.http.replace(w.apiUrl, FakeReply(304));
      await w.controller.check();
      statusIs<UpdateAvailable>();
      expect(
        w.http.requests
            .where((r) => r.url.toString() == w.apiUrl)
            .last
            .headers['If-None-Match'],
        'W/"v1"',
      );
    });

    test('a 304 with a damaged cache refetches without the etag', () async {
      await setUpWorld();
      await w.publish(etag: 'W/"v1"');
      await w.controller.check();
      w.store.write(UpdateKeys.cachedRelease, 'garbage');
      w.http.replace(w.apiUrl, FakeReply(304));
      w.http.on(w.apiUrl, FakeReply(404));
      await w.controller.check();
      statusIs<UpdateNoStableRelease>();
    });

    test('no etag is sent without a cached body', () async {
      await setUpWorld();
      w.store.write(UpdateKeys.etag, 'W/"orphan"');
      await w.publish();
      await w.controller.check();
      expect(
        w.http.requests.first.headers.containsKey('If-None-Match'),
        isFalse,
      );
    });

    test('a 404 clears the cache', () async {
      await setUpWorld();
      await w.publish(etag: 'W/"v1"');
      await w.controller.check();
      w.http.replace(w.apiUrl, FakeReply(404));
      await w.controller.check();
      expect(w.store.read(UpdateKeys.etag), isNull);
      expect(w.store.read(UpdateKeys.cachedRelease), isNull);
    });
  });

  group('download', () {
    Future<void> available() async {
      await w.publish();
      await w.controller.check();
      statusIs<UpdateAvailable>();
    }

    test('downloads, verifies and becomes ready to install', () async {
      await setUpWorld();
      await available();
      final seen = <UpdateStatus>[];
      w.controller.addListener(() => seen.add(w.controller.status));
      await w.controller.download();
      final s = statusIs<UpdateReadyToInstall>();
      expect(s.candidate.version, '1.0.1');
      expect(seen.whereType<UpdateDownloading>(), isNotEmpty);
      final f = File(
        '${w.installer.updateDir.path}/notes-1.0.1-linux-x64.tar.gz',
      );
      expect(f.readAsBytesSync(), w.payload);
    });

    test('checksum mismatch discards the file', () async {
      await setUpWorld();
      await w.publish(
        mutate: (m) {
          ((m['artifacts']! as List)[0] as Map<String, Object?>)['sha256'] =
              'c' * 64;
        },
      );
      await w.controller.check();
      await w.controller.download();
      statusIs<UpdateVerificationFailed>();
      expect(w.installer.updateDir.listSync(), isEmpty);
    });

    test(
      'cancelling returns to "available" and leaves nothing behind',
      () async {
        await setUpWorld();
        await available();
        w.http.replace(
          assetUrl('1.0.1', 'notes-1.0.1-linux-x64.tar.gz'),
          FakeReply(
            200,
            chunks: [
              w.payload.sublist(0, 2000),
              w.payload.sublist(2000, 4000),
              w.payload.sublist(4000),
            ],
            headers: {'content-length': '${w.payload.length}'},
          ),
        );
        w.controller.addListener(() {
          if (w.controller.status is UpdateDownloading) {
            w.controller.cancelDownload();
          }
        });
        await w.controller.download();
        statusIs<UpdateAvailable>();
        expect(w.installer.updateDir.listSync(), isEmpty);
      },
    );

    test(
      'an interrupted download offers Retry, which resumes at the download',
      () async {
        await setUpWorld();
        await available();
        final url = assetUrl('1.0.1', 'notes-1.0.1-linux-x64.tar.gz');
        w.http.replace(
          url,
          FakeReply(
            200,
            chunks: [w.payload.sublist(0, 1000)],
            streamError: const SocketException('reset'),
          ),
        );
        await w.controller.download();
        expect(statusIs<UpdateFailed>().candidate, isNotNull);
        expect(w.installer.updateDir.listSync(), isEmpty);
        await w.publish(); // network is back
        await w.controller.download();
        statusIs<UpdateReadyToInstall>();
      },
    );

    test('insufficient disk space is reported before downloading', () async {
      await setUpWorld();
      await available();
      final c = UpdateController(
        installer: w.installer,
        http: w.http,
        store: w.store,
        autoCheckEnabled: () => true,
        keys: w.keys,
        now: () => w.now,
        downloader: DownloadService(w.http, freeSpace: (_) async => 100),
      );
      addTearDown(c.dispose);
      await c.check();
      await c.download();
      expect(
        (c.status as UpdateFailed).message,
        contains('Not enough free space'),
      );
      expect(
        w.http.count(assetUrl('1.0.1', 'notes-1.0.1-linux-x64.tar.gz')),
        0,
      );
    });

    test('permission denied writing the update directory', () async {
      await setUpWorld();
      await available();
      Directory(w.installer.updateDir.path).createSync(recursive: true);
      Process.runSync('chmod', ['500', w.installer.updateDir.path]);
      try {
        File('${w.installer.updateDir.path}/probe').writeAsStringSync('x');
        markTestSkipped('permissions are not enforced for this user');
        return;
      } on FileSystemException {
        // expected
      }
      await w.controller.download();
      expect(statusIs<UpdateFailed>().message, contains('allowed'));
    });

    test('a platform verification failure deletes the file', () async {
      await setUpWorld();
      await available();
      w.installer.verifyFailure = const UpdateVerificationFailure(
        'Wrong signing certificate.',
      );
      await w.controller.download();
      expect(
        statusIs<UpdateVerificationFailed>().reason,
        contains('certificate'),
      );
      expect(w.installer.updateDir.listSync(), isEmpty);
    });

    test(
      'a download that was blocked in the meantime does not start',
      () async {
        await setUpWorld();
        await available();
        w.installer.block = const UpdateBlock(
          BlockKind.unsupportedOs,
          'Too old.',
        );
        await w.controller.download();
        statusIs<UpdateBlocked>();
      },
    );
  });

  group('install', () {
    Future<void> ready() async {
      await w.publish();
      await w.controller.check();
      await w.controller.download();
      statusIs<UpdateReadyToInstall>();
    }

    test('hands over to the OS and never claims success', () async {
      await setUpWorld();
      await ready();
      await w.controller.install();
      final s = statusIs<UpdateInstallationHandedToOs>();
      expect(s.willRestart, isTrue);
      expect(w.installer.installs, 1);
    });

    test('install is ignored unless the update is ready', () async {
      await setUpWorld();
      await w.controller.install();
      expect(w.installer.installs, 0);
      statusIs<UpdateIdle>();
    });

    test(
      'missing install permission blocks, then retries only on request',
      () async {
        await setUpWorld(platform: androidPlatform);
        await ready();
        w.installer.installResult = const InstallNeedsPermission();
        await w.controller.install();
        expect(
          statusIs<UpdateBlocked>().block.kind,
          BlockKind.installPermission,
        );
        await w.controller.openInstallSettings();
        expect(w.installer.settingsOpened, 1);
        expect(w.installer.installs, 1, reason: 'no automatic retry');
        w.installer.installResult = const InstallHandedToOs(willRestart: false);
        await w.controller.install();
        statusIs<UpdateInstallationHandedToOs>();
        expect(w.installer.installs, 2);
      },
    );

    test('a cancelled install returns to ready', () async {
      await setUpWorld();
      await ready();
      w.installer.installResult = const InstallCancelled();
      await w.controller.install();
      expect(statusIs<UpdateReadyToInstall>().message, isNull);
    });

    test('a failed install reports the reason and can be retried', () async {
      await setUpWorld();
      await ready();
      w.installer.installResult = const InstallFailed('Package conflicts.');
      await w.controller.install();
      expect(statusIs<UpdateReadyToInstall>().message, 'Package conflicts.');
      w.installer.installResult = const InstallHandedToOs(willRestart: true);
      await w.controller.install();
      statusIs<UpdateInstallationHandedToOs>();
    });
  });

  group('next launch', () {
    InstallOutcome outcome(String id, {bool updated = true}) => InstallOutcome(
      id: id,
      updated: updated,
      version: '1.0.1',
      message: updated ? 'Updated to 1.0.1' : 'Not installed',
    );

    test('reports an earlier install once, then stays quiet', () async {
      await setUpWorld();
      w.installer.outcome = outcome('t1');
      await w.controller.resolveLastInstall();
      expect(w.controller.lastOutcome!.message, 'Updated to 1.0.1');

      final again = w.makeController();
      addTearDown(again.dispose);
      await again.resolveLastInstall();
      expect(again.lastOutcome, isNull);

      w.installer.outcome = outcome('t2');
      await again.resolveLastInstall();
      expect(again.lastOutcome, isNotNull);
    });

    test('a successful update clears old downloads', () async {
      await setUpWorld();
      final d = w.installer.updateDir..createSync(recursive: true);
      File('${d.path}/notes-1.0.1-linux-x64.tar.gz').writeAsStringSync('x');
      w.installer.outcome = outcome('t1');
      await w.controller.resolveLastInstall();
      expect(d.listSync(), isEmpty);
    });

    test('a failed install is reported and can be dismissed', () async {
      await setUpWorld();
      w.installer.outcome = outcome('t1', updated: false);
      await w.controller.resolveLastInstall();
      expect(w.controller.lastOutcome!.updated, isFalse);
      w.controller.dismissOutcome();
      expect(w.controller.lastOutcome, isNull);
    });
  });

  group('scheduling', () {
    Future<void> prepare({bool dev = false, bool pin = true}) async {
      await setUpWorld(pinKey: pin);
      await w.publish();
      w.dev = dev;
      w.controller.dispose();
      w.controller = w.makeController();
    }

    test('one automatic check about 30 seconds after start', () async {
      await prepare();
      fakeAsync((async) {
        w.controller.scheduleStartupCheck();
        async.elapse(const Duration(seconds: 29));
        expect(w.http.requests, isEmpty);
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(w.http.count(w.apiUrl), 1);
        expect(w.controller.status, isA<UpdateAvailable>());
        // Scheduling twice does not schedule twice.
        w.controller.scheduleStartupCheck();
        async.elapse(const Duration(hours: 5));
        expect(w.http.count(w.apiUrl), 1);
      });
    });

    test('automatic checks never download or install', () async {
      await prepare();
      fakeAsync((async) {
        w.controller.scheduleStartupCheck();
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(
          w.http.requests.any((r) => r.url.pathSegments.last.endsWith('.gz')),
          isFalse,
        );
        expect(w.installer.installs, 0);
      });
    });

    test(
      'opt-out: nothing is requested when automatic checks are off',
      () async {
        await prepare();
        w.autoCheck = false;
        fakeAsync((async) {
          w.controller.scheduleStartupCheck();
          async.elapse(const Duration(minutes: 5));
          async.flushMicrotasks();
          expect(w.http.requests, isEmpty);
        });
      },
    );

    test('a dev instance never checks by itself', () async {
      await prepare(dev: true);
      fakeAsync((async) {
        w.controller.scheduleStartupCheck();
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(w.http.requests, isEmpty);
      });
    });

    test('at most once per 24 hours, counted from the last attempt', () async {
      await prepare();
      w.store.write(
        UpdateKeys.lastAttempt,
        w.now.subtract(const Duration(hours: 23)).toIso8601String(),
      );
      fakeAsync((async) {
        w.controller.scheduleStartupCheck();
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(w.http.requests, isEmpty);
      });
      w.store.write(
        UpdateKeys.lastAttempt,
        w.now.subtract(const Duration(hours: 25)).toIso8601String(),
      );
      final later = w.makeController();
      addTearDown(later.dispose);
      fakeAsync((async) {
        later.scheduleStartupCheck();
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(w.http.count(w.apiUrl), 1);
      });
    });

    test(
      'a failed attempt is not retried until 24 hours have passed',
      () async {
        await prepare();
        w.http.replace(
          w.apiUrl,
          FakeReply(0, error: const UpdateOfflineException()),
        );
        fakeAsync((async) {
          w.controller.scheduleStartupCheck();
          async.elapse(const Duration(minutes: 1));
          async.flushMicrotasks();
          expect(w.controller.status, isA<UpdateOffline>());
          async.elapse(const Duration(hours: 10));
          expect(w.http.count(w.apiUrl), 1, reason: 'no retry loop');
        });
        final nextLaunch = w.makeController();
        addTearDown(nextLaunch.dispose);
        fakeAsync((async) {
          nextLaunch.scheduleStartupCheck();
          async.elapse(const Duration(minutes: 1));
          async.flushMicrotasks();
          expect(w.http.count(w.apiUrl), 1, reason: 'still inside 24 h');
        });
      },
    );

    test('a rate limit is respected by the next automatic check', () async {
      await prepare();
      w.store.write(
        UpdateKeys.retryAfter,
        w.now.add(const Duration(hours: 2)).toIso8601String(),
      );
      fakeAsync((async) {
        w.controller.scheduleStartupCheck();
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(w.http.requests, isEmpty);
      });
    });

    test('a manual check ignores the 24 hour gate', () async {
      await prepare();
      w.store.write(UpdateKeys.lastAttempt, w.now.toIso8601String());
      await w.controller.check();
      expect(w.http.count(w.apiUrl), 1);
    });

    test('errors in the background are swallowed', () async {
      await prepare();
      w.installer.outcome = null;
      w.http.routes.remove(w.apiUrl); // FakeHttp throws StateError
      fakeAsync((async) {
        w.controller.scheduleStartupCheck();
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(w.controller.status, isA<UpdateFailed>());
      });
    });

    test('disposing cancels the pending check', () async {
      await prepare();
      fakeAsync((async) {
        w.controller.scheduleStartupCheck();
        w.controller.dispose();
        async.elapse(const Duration(minutes: 5));
        expect(w.http.requests, isEmpty);
      });
    });
  });

  group('settings bookkeeping', () {
    test('a full check notifies no settings listener (no write())', () async {
      await setUpWorld();
      final services = AppServices.inMemory();
      addTearDown(services.close);
      var notifications = 0;
      services.settings.addListener(() => notifications++);
      final c = UpdateController(
        installer: w.installer,
        http: w.http,
        store: AppSettingsUpdateStore(services.settings),
        autoCheckEnabled: () => services.settings.autoCheckUpdates,
        keys: w.keys,
        now: () => w.now,
      );
      addTearDown(c.dispose);
      await w.publish(etag: 'W/"1"');
      await c.check();
      w.http.replace(w.apiUrl, FakeReply(304));
      await c.check();
      expect(c.status, isA<UpdateAvailable>());
      expect(notifications, 0);
      // The bookkeeping was persisted nonetheless.
      expect(services.settings.read(UpdateKeys.lastCheck), isNotNull);
      expect(services.settings.read(UpdateKeys.etag), 'W/"1"');
      expect(services.settings.read(UpdateKeys.highestVersion), '1.0.1');
      // The user-facing switch still notifies, as it should.
      services.settings.autoCheckUpdates = false;
      expect(notifications, 1);
    });
  });
}
