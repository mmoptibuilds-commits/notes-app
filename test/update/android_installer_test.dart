import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/update/android_installer.dart';
import 'package:notes/update/github_release_client.dart';
import 'package:notes/update/installer.dart';
import 'package:notes/update/manifest.dart';
import 'package:notes/update/pinned_keys.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AndroidUpdateInstaller installer;
  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> handlers;

  Map<String, Object?> okVersion({
    int code = 20261122,
    int sdk = 34,
    List<String> abis = const ['arm64-v8a', 'armeabi-v7a'],
    String pkg = 'com.mmoptibuilds.notes',
  }) => {
    'packageName': pkg,
    'versionCode': code,
    'versionName': '1.0.0',
    'sdkInt': sdk,
    'abis': abis,
  };

  Map<String, Object?> okApk({
    String pkg = 'com.mmoptibuilds.notes',
    int code = 20261123,
    List<String>? signers,
    bool supported = true,
  }) => {
    'supported': supported,
    'packageName': pkg,
    'versionCode': code,
    'signerSha256': signers ?? [kReleaseCertSha256],
  };

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('notes_android_installer');
    calls = [];
    handlers = {
      'installedVersion': (_) => okVersion(),
      'updateCacheDir': (_) => '${tmp.path}/updates',
      'freeSpace': (_) => 123456789,
      'canInstall': (_) => true,
      'inspectApk': (_) => okApk(),
      'install': (_) => {'status': 'handedToOs'},
      'openInstallSettings': (_) => null,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(kUpdaterChannelName), (
          call,
        ) async {
          calls.add(call);
          final h = handlers[call.method];
          if (h == null) throw MissingPluginException(call.method);
          return h(call);
        });
    installer = AndroidUpdateInstaller(
      installTimeout: const Duration(milliseconds: 300),
      now: () => DateTime.utc(2026, 12, 2),
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(kUpdaterChannelName),
          null,
        );
    tmp.deleteSync(recursive: true);
  });

  UpdateCandidate candidate({int code = 20261123, String? cert}) {
    final artifact = ManifestArtifact(
      platform: 'android',
      arch: 'arm64',
      filename: 'notes-1.0.1-android-arm64.apk',
      sha256: sha64b,
      size: 2000,
      versionCode: code,
      certSha256: cert ?? kReleaseCertSha256,
    );
    return UpdateCandidate(
      release: const GithubRelease(
        tag: 'v1.0.1',
        version: '1.0.1',
        notes: '',
        assets: [],
      ),
      manifest: UpdateManifest(
        version: '1.0.1',
        buildNumber: code,
        publishedAt: DateTime.utc(2026, 12, 1),
        expires: DateTime.utc(2027, 6, 1),
        artifacts: [artifact],
      ),
      artifact: artifact,
      assetUrl: Uri.parse('https://example.test/a.apk'),
      signed: true,
      platform: androidPlatformForTest,
    );
  }

  Future<ReadyUpdate> ready({int code = 20261123, String? cert}) async {
    final f = File('${tmp.path}/notes-1.0.1-android-arm64.apk')
      ..writeAsBytesSync([1, 2, 3]);
    return ReadyUpdate(candidate(code: code, cert: cert), f);
  }

  Matcher verificationFails(String part) => throwsA(
    isA<UpdateVerificationFailure>().having(
      (e) => e.reason,
      'reason',
      contains(part),
    ),
  );

  test('the pinned certificate is the release certificate', () {
    expect(
      kReleaseCertSha256,
      File('tool/release_cert_sha256.txt').readAsStringSync().trim(),
    );
  });

  group('prepare', () {
    test('reports the installed package version from the platform', () async {
      final info = await installer.prepare();
      expect(info.installedBuild, 20261122);
      expect(info.installedVersion, '1.0.0');
      expect(info.updateDir.path, '${tmp.path}/updates');
      expect(info.block, isNull);
      expect(info.platform.os, UpdateOs.android);
      expect(info.platform.arch, 'arm64');
    });

    test('Android older than 9 is blocked with guidance', () async {
      handlers['installedVersion'] = (_) => okVersion(sdk: 27);
      final info = await installer.prepare();
      expect(info.block!.kind, BlockKind.unsupportedOs);
      expect(info.block!.message, contains('Android 9'));
    });

    test('a phone without arm64 is blocked', () async {
      handlers['installedVersion'] = (_) => okVersion(abis: ['x86_64']);
      expect(
        (await installer.prepare()).block!.kind,
        BlockKind.unsupportedArch,
      );
    });

    test('a different package id is blocked', () async {
      handlers['installedVersion'] = (_) => okVersion(pkg: 'com.other');
      expect((await installer.prepare()).block, isNotNull);
    });

    test('a build without the Kotlin plugin degrades to a block', () async {
      handlers.remove('installedVersion');
      final info = await installer.prepare();
      expect(info.block!.message, contains('not available in this build'));
      expect(info.installedBuild, greaterThan(0));
    });

    test('free space comes from the platform; failures mean unknown', () async {
      expect(await installer.freeSpace('/x'), 123456789);
      handlers['freeSpace'] = (_) => throw PlatformException(code: 'x');
      expect(await installer.freeSpace('/x'), isNull);
    });
  });

  group('verifyDownloaded', () {
    late InstallerInfo info;
    setUp(() async => info = await installer.prepare());

    test('the genuine package passes', () async {
      await installer.verifyDownloaded(await ready(), info);
      expect(calls.last.method, 'inspectApk');
    });

    test('wrong package name', () async {
      handlers['inspectApk'] = (_) => okApk(pkg: 'com.evil.notes');
      await expectLater(
        installer.verifyDownloaded(await ready(), info),
        verificationFails('different app'),
      );
    });

    test('wrong signing certificate', () async {
      handlers['inspectApk'] = (_) => okApk(signers: ['f' * 64]);
      await expectLater(
        installer.verifyDownloaded(await ready(), info),
        verificationFails('different certificate'),
      );
    });

    test('no signer, or more than one signer', () async {
      handlers['inspectApk'] = (_) => okApk(signers: []);
      await expectLater(
        installer.verifyDownloaded(await ready(), info),
        verificationFails('exactly one'),
      );
      handlers['inspectApk'] = (_) =>
          okApk(signers: [kReleaseCertSha256, 'a' * 64]);
      await expectLater(
        installer.verifyDownloaded(await ready(), info),
        verificationFails('exactly one'),
      );
    });

    test('the certificate comparison ignores case', () async {
      handlers['inspectApk'] = (_) =>
          okApk(signers: [kReleaseCertSha256.toUpperCase()]);
      await installer.verifyDownloaded(await ready(), info);
    });

    test(
      'version code must equal the manifest and exceed the installed one',
      () async {
        handlers['inspectApk'] = (_) => okApk(code: 20261999);
        await expectLater(
          installer.verifyDownloaded(await ready(), info),
          verificationFails('not the version'),
        );
        handlers['inspectApk'] = (_) => okApk(code: 20261122);
        await expectLater(
          installer.verifyDownloaded(await ready(code: 20261122), info),
          verificationFails('not newer'),
        );
      },
    );

    test('a manifest naming another certificate is refused', () async {
      await expectLater(
        installer.verifyDownloaded(await ready(cert: 'b' * 64), info),
        verificationFails('different signing certificate'),
      );
    });

    test(
      'an unreadable package or unsupported inspection fails closed',
      () async {
        handlers['inspectApk'] = (_) => throw PlatformException(code: 'bad');
        await expectLater(
          installer.verifyDownloaded(await ready(), info),
          verificationFails('could not read'),
        );
        handlers['inspectApk'] = (_) => okApk(supported: false);
        await expectLater(
          installer.verifyDownloaded(await ready(), info),
          verificationFails('cannot check'),
        );
      },
    );
  });

  group('install', () {
    late InstallerInfo info;
    setUp(() async => info = await installer.prepare());

    test('hands over to the OS and leaves a pending marker', () async {
      info.updateDir.createSync(recursive: true); // the platform makes it
      final r = await installer.install(await ready(), info);
      expect(r, isA<InstallHandedToOs>());
      expect((r as InstallHandedToOs).willRestart, isFalse);
      final pending = File('${info.updateDir.path}/pending.json');
      expect(pending.existsSync(), isTrue);
      expect(jsonDecode(pending.readAsStringSync())['toVersion'], '1.0.1');
      expect(
        calls.map((c) => c.method),
        containsAllInOrder(['canInstall', 'install']),
      );
      expect(calls.last.arguments['path'], endsWith('.apk'));
    });

    test(
      'without permission it asks to open settings and installs nothing',
      () async {
        handlers['canInstall'] = (_) => false;
        final r = await installer.install(await ready(), info);
        expect(r, isA<InstallNeedsPermission>());
        expect(calls.where((c) => c.method == 'install'), isEmpty);
        await installer.openInstallSettings();
        expect(calls.last.method, 'openInstallSettings');
      },
    );

    test('the user cancelling in the system dialog', () async {
      info.updateDir.createSync(recursive: true);
      handlers['install'] = (_) => {'status': 'cancelled'};
      expect(
        await installer.install(await ready(), info),
        isA<InstallCancelled>(),
      );
      expect(File('${info.updateDir.path}/pending.json').existsSync(), isFalse);
    });

    test('a failure from the package installer carries its message', () async {
      handlers['install'] = (_) => {'status': 'failed', 'message': 'Conflict'};
      final r = await installer.install(await ready(), info);
      expect((r as InstallFailed).message, 'Conflict');
    });

    test('a platform exception or timeout is a failure, not success', () async {
      handlers['install'] = (_) =>
          throw PlatformException(code: 'x', message: 'boom');
      expect(
        await installer.install(await ready(), info),
        isA<InstallFailed>(),
      );
      handlers['install'] = (_) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return {'status': 'handedToOs'};
      };
      final r = await installer.install(await ready(), info);
      expect(r, isA<InstallFailed>());
    });
  });

  group('next launch', () {
    Future<InstallerInfo> infoWith(int code) async {
      handlers['installedVersion'] = (_) => okVersion(code: code);
      return installer.prepare();
    }

    Future<void> pendingFor(InstallerInfo info, {int code = 20261123}) async {
      info.updateDir.createSync(recursive: true);
      File('${info.updateDir.path}/pending.json').writeAsStringSync(
        jsonEncode({
          'toVersion': '1.0.1',
          'toVersionCode': code,
          'time': '2026-12-02T00:00:00.000Z',
        }),
      );
    }

    test('the new version is running: "Updated to"', () async {
      final info = await infoWith(20261123);
      await pendingFor(info);
      final o = (await installer.lastOutcome(info))!;
      expect(o.updated, isTrue);
      expect(o.message, 'Updated to 1.0.1.');
      expect(o.id, startsWith('android:'));
      expect(await installer.lastOutcome(info), isNull, reason: 'cleared');
    });

    test(
      'the old version is still running: the update was not installed',
      () async {
        final info = await infoWith(20261122);
        await pendingFor(info);
        final o = (await installer.lastOutcome(info))!;
        expect(o.updated, isFalse);
        expect(o.message, contains('was not installed'));
      },
    );

    test('nothing pending, or a damaged marker, reports nothing', () async {
      final info = await infoWith(20261123);
      expect(await installer.lastOutcome(info), isNull);
      info.updateDir.createSync(recursive: true);
      File('${info.updateDir.path}/pending.json').writeAsStringSync('{{');
      expect(await installer.lastOutcome(info), isNull);
    });
  });
}

const androidPlatformForTest = UpdatePlatform(UpdateOs.android, 'arm64');
