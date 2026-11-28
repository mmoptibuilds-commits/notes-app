import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:notes/update/github_release_client.dart';
import 'package:notes/update/manifest.dart';
import 'package:notes/update/installer.dart';
import 'package:notes/update/pinned_keys.dart';
import 'package:notes/update/update_controller.dart';
import 'package:notes/update/update_state.dart';

import 'fake_http.dart';
import 'fake_installer.dart';
import 'fixtures.dart';

const linuxPlatform = UpdatePlatform(UpdateOs.linux, 'x64');
const androidPlatform = UpdatePlatform(UpdateOs.android, 'arm64');

String assetUrl(String version, String name) =>
    'https://github.com/mmoptibuilds-commits/notes-app/releases/download/v$version/$name';

/// A complete fake world: GitHub, a signing key, an installer and a
/// controller wired together, all in memory or in a temp directory.
class World {
  World._(this.signer, this.tmp, this.platform);

  static Future<World> create({
    UpdatePlatform platform = linuxPlatform,
    bool pinKey = true,
  }) async {
    final signer = await TestSigner.create();
    final tmp = Directory.systemTemp.createTempSync('notes_update_world');
    final w = World._(signer, tmp, platform);
    w.installer = FakeInstaller(
      platform: platform,
      updateDir: Directory('${tmp.path}/updates'),
      accepts: platform.os == UpdateOs.android,
    );
    w.keys = pinKey ? [signer.pinned] : const [];
    w.now = DateTime.utc(2026, 12, 2, 10);
    w.controller = w.makeController();
    return w;
  }

  final TestSigner signer;
  final Directory tmp;
  final UpdatePlatform platform;
  final http = FakeHttp();
  final store = MemoryUpdateStore();
  late final FakeInstaller installer;
  late List<PinnedKey> keys;
  late DateTime now;
  late UpdateController controller;
  bool autoCheck = true;
  bool dev = false;

  /// The bytes of the published artifact.
  final payload = Uint8List.fromList(List.generate(6000, (i) => (i * 7) % 256));
  String get payloadSha => sha256.convert(payload).toString();

  String get apiUrl => kLatestReleaseUrl.toString();

  UpdateController makeController({UpdateStateStore? stateStore}) =>
      UpdateController(
        installer: installer,
        http: http,
        store: stateStore ?? store,
        autoCheckEnabled: () => autoCheck,
        keys: keys,
        now: () => now,
        devInstance: dev,
        assetTimeout: const Duration(milliseconds: 300),
        client: GithubReleaseClient(
          http,
          totalTimeout: const Duration(milliseconds: 300),
          now: () => now,
        ),
      );

  void dispose() {
    controller.dispose();
    Process.runSync('chmod', ['-R', 'u+rwx', tmp.path]);
    tmp.deleteSync(recursive: true);
  }

  String get artifactName => platform.os == UpdateOs.android
      ? 'notes-VERSION-android-arm64.apk'
      : 'notes-VERSION-linux-x64.tar.gz';

  /// Publishes a release the way the release tooling would.
  Future<void> publish({
    String version = '1.0.1',
    int build = 20261123,
    bool prerelease = false,
    bool sign = true,
    TestSigner? signWith,
    String? sigKeyId,
    String expires = '2027-06-01T00:00:00Z',
    void Function(Map<String, Object?> manifest)? mutate,
    bool includeManifest = true,
    bool includeArtifact = true,
    int? assetSizeOverride,
    String? etag,
    String notes = 'Fixes and small improvements.',
    bool replaceApi = true,
  }) async {
    final m = manifestMap(
      version: version,
      build: build,
      expires: expires,
      linuxSha: payloadSha,
      linuxSize: payload.length,
      apkSha: payloadSha,
      apkSize: payload.length,
    );
    mutate?.call(m);
    final manifest = encodeManifest(m);
    final name = artifactName.replaceFirst('VERSION', version);
    final assets = <Map<String, Object?>>[
      if (includeManifest) _asset(version, kManifestAssetName, manifest.length),
      if (includeManifest && sign) _asset(version, kSignatureAssetName, 200),
      if (includeArtifact)
        _asset(version, name, assetSizeOverride ?? payload.length),
    ];
    final json = {
      'tag_name': 'v$version',
      'draft': false,
      'prerelease': prerelease,
      'body': notes,
      'assets': assets,
    };
    final reply = FakeReply(
      200,
      body: utf8.encode(jsonEncode(json)),
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'etag': ?etag,
      },
    );
    if (replaceApi) {
      http.replace(apiUrl, reply);
    } else {
      http.on(apiUrl, reply);
    }
    http.replace(
      assetUrl(version, kManifestAssetName),
      FakeReply(200, body: manifest, headers: _octet),
    );
    if (sign) {
      final sig = await (signWith ?? signer).signFile(
        manifest,
        keyId: sigKeyId,
      );
      http.replace(
        assetUrl(version, kSignatureAssetName),
        FakeReply(200, body: sig, headers: _octet),
      );
    }
    http.replace(
      assetUrl(version, name),
      FakeReply(
        200,
        body: payload,
        headers: {..._octet, 'content-length': '${payload.length}'},
      ),
    );
  }

  static const _octet = {'content-type': 'application/octet-stream'};

  Map<String, Object?> _asset(String v, String name, int size) => {
    'name': name,
    'size': size,
    'browser_download_url': assetUrl(v, name),
  };
}
