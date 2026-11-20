import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/app_version.dart';
import '../data/app_settings.dart';
import 'download_service.dart';
import 'github_release_client.dart';
import 'installer.dart';
import 'manifest.dart';
import 'pinned_keys.dart';
import 'update_http.dart';
import 'update_state.dart';
import 'update_status.dart';
import 'version_compare.dart';

/// Checks for, downloads and hands over updates. Owns the [status] the
/// Updates screen shows.
///
/// It never downloads or installs without an explicit call from the user
/// interface. A scheduled check only ever asks GitHub whether a newer stable
/// release exists.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.installer,
    required UpdateHttp http,
    required this.store,
    required this.autoCheckEnabled,
    GithubReleaseClient? client,
    DownloadService? downloader,
    this.keys = kPinnedKeys,
    DateTime Function()? now,
    this.devInstance = false,
    this.startupDelay = const Duration(seconds: 30),
    this.checkInterval = const Duration(hours: 24),
    this.assetTimeout = const Duration(seconds: 20),
  }) : _http = http,
       _now = now ?? DateTime.now,
       _client = client ?? GithubReleaseClient(http, now: now),
       _downloader =
           downloader ?? DownloadService(http, freeSpace: installer.freeSpace);

  /// The controller the app uses: real network, settings-backed bookkeeping,
  /// and automatic checks only for a normal (non-dev) instance.
  factory UpdateController.forApp({
    required AppSettings settings,
    required UpdateInstaller installer,
    UpdateHttp? http,
  }) {
    final h = http ?? IoUpdateHttp();
    return UpdateController(
      installer: installer,
      http: h,
      store: AppSettingsUpdateStore(settings),
      autoCheckEnabled: () => settings.autoCheckUpdates,
      devInstance: Platform.environment['NOTES_DATA_DIR'] != null,
    );
  }

  final UpdateInstaller installer;
  final UpdateStateStore store;
  final bool Function() autoCheckEnabled;
  final List<PinnedKey> keys;

  /// A dev instance (`NOTES_DATA_DIR` set) never checks by itself.
  final bool devInstance;
  final Duration startupDelay;
  final Duration checkInterval;

  /// Longest wait for each small manifest or signature file.
  final Duration assetTimeout;

  final UpdateHttp _http;
  final DateTime Function() _now;
  final GithubReleaseClient _client;
  final DownloadService _downloader;

  UpdateStatus _status = const UpdateIdle();
  UpdateStatus get status => _status;

  InstallOutcome? _outcome;

  /// What an earlier install turned out to be ("Updated to 1.0.1"), reported
  /// once on the first launch after it.
  InstallOutcome? get lastOutcome => _outcome;

  InstallerInfo? _info;

  /// The installed version as the platform reports it (falls back to the
  /// compiled-in one before the first check).
  String get installedVersion => _info?.installedVersion ?? appVersionText;
  int get installedBuild => _info?.installedBuild ?? appBuildNumber;

  /// The last time a check reached a conclusion.
  DateTime? get lastSuccessfulCheck => _readDate(UpdateKeys.lastCheck);

  ReadyUpdate? _ready;
  CancelToken? _cancel;
  Timer? _timer;
  bool _disposed = false;
  bool _startupScheduled = false;

  bool get busy =>
      _status is UpdateChecking ||
      _status is UpdateDownloading ||
      _status is UpdateInstalling;

  void _set(UpdateStatus s) {
    if (_disposed) return;
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _cancel?.cancel();
    super.dispose();
  }

  // Scheduling ---------------------------------------------------------------

  /// Call once after the first frame. Reports an earlier install's result and,
  /// after [startupDelay], runs one check if automatic checks are on and none
  /// was attempted in the last 24 hours. Does nothing in a dev instance.
  /// One attempt per launch: there is no retry loop.
  void scheduleStartupCheck() {
    if (_startupScheduled || devInstance || _disposed) return;
    _startupScheduled = true;
    unawaited(resolveLastInstall());
    _timer = Timer(startupDelay, () => unawaited(_startupCheck()));
  }

  Future<void> _startupCheck() async {
    try {
      if (_disposed || !autoCheckEnabled() || busy) return;
      final last = _readDate(UpdateKeys.lastAttempt);
      if (last != null && _now().difference(last) < checkInterval) return;
      final until = _readDate(UpdateKeys.retryAfter);
      if (until != null && _now().isBefore(until)) return;
      await check(manual: false);
    } on Object {
      // A background check must never surface an error.
    }
  }

  /// Reads what happened to the last install attempt and exposes it once.
  Future<void> resolveLastInstall() async {
    try {
      final info = await installer.prepare();
      _info = info;
      final outcome = await installer.lastOutcome(info);
      if (outcome == null ||
          store.read(UpdateKeys.ackedOutcome) == outcome.id) {
        return;
      }
      store.write(UpdateKeys.ackedOutcome, outcome.id);
      _outcome = outcome;
      if (outcome.updated) await cleanUpdateDir(info.updateDir);
      if (!_disposed) notifyListeners();
    } on Object {
      // Nothing to report if the platform cannot say.
    }
  }

  void dismissOutcome() {
    if (_outcome == null) return;
    _outcome = null;
    notifyListeners();
  }

  // Checking -----------------------------------------------------------------

  /// Asks GitHub for the latest stable release and decides what it means.
  /// [manual] only documents the caller; both paths behave the same.
  Future<void> check({bool manual = true}) async {
    if (busy || _disposed) return;
    _ready = null;
    _lastCandidate = null;
    _set(const UpdateChecking());
    store.write(UpdateKeys.lastAttempt, _now().toUtc().toIso8601String());
    try {
      final info = await installer.prepare();
      _info = info;
      final fetch = await _latest();
      switch (fetch) {
        case ReleaseNone():
          _concluded();
          _set(const UpdateNoStableRelease());
        case ReleaseRateLimited(:final resetAt):
          if (resetAt != null) {
            store.write(
              UpdateKeys.retryAfter,
              resetAt.toUtc().toIso8601String(),
            );
          }
          _set(UpdateRateLimited(resetAt));
        case ReleaseOffline():
          _set(const UpdateOffline());
        case ReleaseFailed(:final message):
          _set(UpdateFailed(message));
        case ReleaseNotModified():
          _set(const UpdateFailed('GitHub sent an unexpected answer.'));
        case ReleaseFetched(:final release):
          store.write(UpdateKeys.retryAfter, null);
          await _evaluate(release, info);
      }
    } on TimeoutException {
      _set(const UpdateFailed('GitHub did not answer in time.'));
    } on UpdateOfflineException {
      _set(const UpdateOffline());
    } on SocketException {
      _set(const UpdateOffline());
    } on ManifestException catch (e) {
      _set(UpdateVerificationFailed(e.message));
    } on Object catch (e) {
      _set(UpdateFailed(_describe(e)));
    }
  }

  void _concluded() =>
      store.write(UpdateKeys.lastCheck, _now().toUtc().toIso8601String());

  Future<ReleaseFetch> _latest() async {
    final cached = store.read(UpdateKeys.cachedRelease);
    final etag = store.read(UpdateKeys.etag);
    var fetch = await _client.fetchLatest(
      etag: cached != null && etag != null ? etag : null,
    );
    if (fetch is ReleaseNotModified) {
      final release = cached == null
          ? null
          : GithubReleaseClient.parseCached(cached);
      if (release != null) {
        return ReleaseFetched(release, etag: etag, rawJson: cached!);
      }
      store.write(UpdateKeys.etag, null);
      store.write(UpdateKeys.cachedRelease, null);
      fetch = await _client.fetchLatest();
    }
    if (fetch is ReleaseFetched) {
      final small = fetch.rawJson.length <= 256 * 1024;
      store.write(UpdateKeys.etag, small ? fetch.etag : null);
      store.write(UpdateKeys.cachedRelease, small ? fetch.rawJson : null);
    } else if (fetch is ReleaseNone) {
      store.write(UpdateKeys.etag, null);
      store.write(UpdateKeys.cachedRelease, null);
    }
    return fetch;
  }

  Future<void> _evaluate(GithubRelease release, InstallerInfo info) async {
    final manifestAsset = release.asset(kManifestAssetName);
    if (manifestAsset == null) {
      _set(
        const UpdateFailed(
          'The latest release does not include update information.',
        ),
      );
      return;
    }
    final manifestBytes = await _fetchAsset(manifestAsset, kMaxManifestBytes);
    Uint8List? sig;
    final sigAsset = release.asset(kSignatureAssetName);
    if (keys.isNotEmpty && sigAsset != null) {
      sig = await _fetchAsset(sigAsset, kMaxSignatureBytes);
    }
    final verified = await verifyManifest(
      manifestBytes: manifestBytes,
      signatureBytes: sig,
      keys: keys,
      expectedVersion: release.version,
      now: _now(),
    );
    final manifest = verified.manifest;

    // Replay protection: a signed manifest older than one already seen is a
    // rollback attempt. Only authenticated manifests move the mark.
    if (verified.signed) {
      final hv = store.read(UpdateKeys.highestVersion);
      final hb = int.tryParse(store.read(UpdateKeys.highestBuild) ?? '');
      if (hv != null && hb != null) {
        if (compareReleases(manifest.version, manifest.buildNumber, hv, hb) <
            0) {
          _set(
            const UpdateVerificationFailed(
              'This release is older than one Notes has already verified.',
            ),
          );
          return;
        }
      }
      store.write(UpdateKeys.highestVersion, manifest.version);
      store.write(UpdateKeys.highestBuild, '${manifest.buildNumber}');
    }

    final platform = info.platform;
    final artifact = manifest.artifactFor(platform.name, platform.arch);
    if (artifact == null) {
      _concluded();
      _set(const UpdateNoPlatformRelease());
      return;
    }
    final asset = release.asset(artifact.filename);
    if (asset == null) {
      _concluded();
      _set(const UpdateNoPlatformRelease());
      return;
    }
    if (asset.size != artifact.size) {
      _set(
        const UpdateVerificationFailed(
          'The release file is not the size its manifest declares.',
        ),
      );
      return;
    }

    final newer = switch (platform.os) {
      UpdateOs.android => isNewerAndroidVersionCode(
        installedVersionCode: info.installedBuild,
        candidateVersionCode: artifact.versionCode ?? 0,
      ),
      UpdateOs.linux => isNewerLinuxVersion(
        installedVersion: info.installedVersion,
        installedBuild: info.installedBuild,
        candidateVersion: manifest.version,
        candidateBuild: manifest.buildNumber,
      ),
      UpdateOs.other => false,
    };
    _concluded();
    if (!newer) {
      _set(const UpdateUpToDate());
      return;
    }
    final candidate = UpdateCandidate(
      release: release,
      manifest: manifest,
      artifact: artifact,
      assetUrl: asset.downloadUrl,
      signed: verified.signed,
      platform: platform,
    );
    final block = _blockFor(candidate, info);
    _set(
      block == null
          ? UpdateAvailable(candidate)
          : UpdateBlocked(block, candidate: candidate),
    );
  }

  UpdateBlock? _blockFor(UpdateCandidate c, InstallerInfo info) {
    if (info.block != null) return info.block;
    if (!c.signed && !installer.acceptsUnsignedManifest) {
      return const UpdateBlock(
        BlockKind.signingKeyNotProvisioned,
        'Release signing key not provisioned.',
      );
    }
    return null;
  }

  Future<Uint8List> _fetchAsset(GithubAsset asset, int maxBytes) =>
      _fetchAssetUnbounded(asset, maxBytes).timeout(assetTimeout);

  Future<Uint8List> _fetchAssetUnbounded(
    GithubAsset asset,
    int maxBytes,
  ) async {
    final response = await getFollowingRedirects(_http, asset.downloadUrl);
    if (response.status != 200) {
      await response.close();
      throw UpdateProtocolException(
        'GitHub answered with status ${response.status} for an update file.',
      );
    }
    final type = (response.headers['content-type'] ?? '').toLowerCase();
    if (type.contains('text/html')) {
      await response.close();
      throw const UpdateProtocolException(
        'GitHub sent a web page instead of an update file.',
      );
    }
    return readBodyCapped(response, maxBytes: maxBytes);
  }

  // Downloading --------------------------------------------------------------

  /// Downloads and verifies the update found by the last check. Only ever
  /// called from the user interface.
  Future<void> download() async {
    final candidate = switch (_status) {
      UpdateAvailable(:final candidate) => candidate,
      UpdateFailed(:final candidate?) => candidate,
      UpdateVerificationFailed() => _lastCandidate,
      _ => null,
    };
    if (candidate == null || busy) return;
    _lastCandidate = candidate;
    _ready = null;
    final token = _cancel = CancelToken();
    _set(UpdateDownloading(candidate, 0, candidate.size));
    var lastPercent = -1;
    try {
      final info = await installer.prepare();
      _info = info;
      final block = _blockFor(candidate, info);
      if (block != null) {
        _set(UpdateBlocked(block, candidate: candidate));
        return;
      }
      final file = await _downloader.download(
        url: candidate.assetUrl,
        dir: info.updateDir,
        filename: candidate.artifact.filename,
        sha256Hex: candidate.artifact.sha256,
        size: candidate.artifact.size,
        cancel: token,
        onProgress: (received, total) {
          final percent = total <= 0 ? 0 : received * 100 ~/ total;
          if (percent == lastPercent) return;
          lastPercent = percent;
          _set(UpdateDownloading(candidate, received, total));
        },
      );
      final ready = ReadyUpdate(candidate, file);
      try {
        await installer.verifyDownloaded(ready, info);
      } on UpdateVerificationFailure catch (e) {
        await _deleteQuietly(file);
        _set(UpdateVerificationFailed(e.reason));
        return;
      }
      await cleanUpdateDir(info.updateDir, keep: candidate.artifact.filename);
      _ready = ready;
      _set(UpdateReadyToInstall(candidate));
    } on DownloadException catch (e) {
      switch (e.kind) {
        case DownloadFailure.cancelled:
          _set(UpdateAvailable(candidate));
        case DownloadFailure.offline:
          _set(const UpdateOffline());
        case DownloadFailure.sizeMismatch:
        case DownloadFailure.checksumMismatch:
          _set(UpdateVerificationFailed(e.message));
        case DownloadFailure.interrupted:
        case DownloadFailure.http:
        case DownloadFailure.contentType:
        case DownloadFailure.diskSpace:
        case DownloadFailure.permission:
        case DownloadFailure.unsafeName:
          _set(UpdateFailed(e.message, candidate: candidate));
      }
    } on Object catch (e) {
      _set(UpdateFailed(_describe(e), candidate: candidate));
    } finally {
      if (identical(_cancel, token)) _cancel = null;
    }
  }

  UpdateCandidate? _lastCandidate;

  /// Cancels a running download. The partial file is deleted.
  void cancelDownload() => _cancel?.cancel();

  // Installing ---------------------------------------------------------------

  /// Hands the verified update to the platform. Only called after the user
  /// confirmed. Never reports success: see [UpdateInstallationHandedToOs].
  Future<void> install() async {
    final ready = _ready;
    final status = _status;
    final allowed =
        status is UpdateReadyToInstall ||
        // Android reported the hand-over, but the user may have dismissed the
        // system dialog: allow trying again.
        (status is UpdateInstallationHandedToOs && !status.willRestart) ||
        (status is UpdateBlocked &&
            status.block.kind == BlockKind.installPermission);
    if (ready == null || !allowed) return;
    final candidate = ready.candidate;
    _set(UpdateInstalling(candidate));
    try {
      final info = _info ?? await installer.prepare();
      final result = await installer.install(ready, info);
      switch (result) {
        case InstallHandedToOs(:final willRestart):
          _set(
            UpdateInstallationHandedToOs(candidate, willRestart: willRestart),
          );
        case InstallNeedsPermission():
          _set(
            UpdateBlocked(
              const UpdateBlock(
                BlockKind.installPermission,
                'Android needs your permission before Notes can install '
                'updates.',
              ),
              candidate: candidate,
            ),
          );
        case InstallCancelled():
          _set(UpdateReadyToInstall(candidate));
        case InstallFailed(:final message):
          _set(UpdateReadyToInstall(candidate, message: message));
      }
    } on Object catch (e) {
      _set(UpdateReadyToInstall(candidate, message: _describe(e)));
    }
  }

  /// Android: opens the system page that lets Notes install updates. The user
  /// returns and presses Install again; nothing retries by itself.
  Future<void> openInstallSettings() => installer.openInstallSettings();

  // Helpers ------------------------------------------------------------------

  DateTime? _readDate(String key) {
    final raw = store.read(key);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on Object {
      // Nothing more to do.
    }
  }

  String _describe(Object e) {
    if (e is UpdateProtocolException) return e.message;
    if (e is FileSystemException) return 'A file operation failed.';
    return 'Something went wrong. Try again later.';
  }
}
