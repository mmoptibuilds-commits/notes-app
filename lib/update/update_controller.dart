import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

/// Checks for, downloads and hands over updates. Automatic work may check and
/// download a signed release, but installation always requires user action.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.installer,
    required UpdateHttp http,
    required this.store,
    required this.autoCheckEnabled,
    this.autoSettings,
    GithubReleaseClient? client,
    DownloadService? downloader,
    this.keys = kPinnedKeys,
    DateTime Function()? now,
    this.devInstance = false,
    this.startupDelay = const Duration(seconds: 3),
    this.checkInterval = const Duration(hours: 24),
    this.retryBaseDelay = const Duration(hours: 1),
    this.maxRetryDelay = const Duration(hours: 24),
    this.assetTimeout = const Duration(seconds: 20),
  }) : _http = http,
       _now = now ?? DateTime.now,
       _client = client ?? GithubReleaseClient(http, now: now),
       _downloader =
           downloader ?? DownloadService(http, freeSpace: installer.freeSpace) {
    _observedAutoEnabled = autoCheckEnabled();
    autoSettings?.addListener(_onAutoSettingsChanged);
  }

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
      autoSettings: settings,
      devInstance: Platform.environment['NOTES_DATA_DIR'] != null,
    );
  }

  final UpdateInstaller installer;
  final UpdateStateStore store;
  final bool Function() autoCheckEnabled;
  final List<PinnedKey> keys;
  final AppSettings? autoSettings;

  /// A dev instance (`NOTES_DATA_DIR` set) never checks by itself.
  final bool devInstance;
  final Duration startupDelay;
  final Duration checkInterval;
  final Duration retryBaseDelay;
  final Duration maxRetryDelay;

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
  _ReadyProof? _proof;
  CancelToken? _cancel;
  Timer? _timer;
  Timer? _retryTimer;
  Future<bool>? _restoreFuture;
  bool _disposed = false;
  bool _startupScheduled = false;
  bool _automaticDownload = false;
  bool _readyPromptSnoozed = false;
  late bool _observedAutoEnabled;

  bool get shouldShowReadyPrompt =>
      _status is UpdateReadyToInstall && !_readyPromptSnoozed;

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
    _retryTimer?.cancel();
    _cancel?.cancel();
    autoSettings?.removeListener(_onAutoSettingsChanged);
    super.dispose();
  }

  // Scheduling ---------------------------------------------------------------

  /// Call once after the first frame. Restores a verified ready artifact and
  /// promptly checks when the successful-check interval or retry backoff is due.
  void scheduleStartupCheck() {
    if (_startupScheduled || devInstance || _disposed) return;
    _startupScheduled = true;
    _restoreFuture = _restoreAndResolve();
    _timer = Timer(startupDelay, () => unawaited(_startupCheck()));
  }

  Future<bool> _restoreAndResolve() async {
    await resolveLastInstall();
    return restoreReady();
  }

  Future<void> _startupCheck() async {
    await checkAutomatically();
  }

  /// Checks on app start and resume when allowed by the successful-check
  /// interval and transient failure backoff.
  Future<void> checkAutomatically() async {
    try {
      if (_disposed || devInstance || !autoCheckEnabled() || busy) return;
      final restored = await (_restoreFuture ??= restoreReady());
      if (restored || _status is UpdateReadyToInstall) return;
      final until = _readDate(UpdateKeys.retryAfter);
      if (until != null && _now().isBefore(until)) {
        _queueRetry(until);
        return;
      }
      final failures =
          int.tryParse(store.read(UpdateKeys.failureCount) ?? '') ?? 0;
      final last = lastSuccessfulCheck;
      if (failures == 0 &&
          last != null &&
          _now().difference(last) < checkInterval) {
        return;
      }
      await check(manual: false);
    } on Object {
      // A background check must never surface an error.
    }
  }

  void _onAutoSettingsChanged() {
    final enabled = autoCheckEnabled();
    if (enabled == _observedAutoEnabled) return;
    _observedAutoEnabled = enabled;
    if (!enabled) {
      _timer?.cancel();
      _timer = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      if (_automaticDownload) cancelDownload();
      return;
    }
    if (_startupScheduled) {
      final retryAt = _readDate(UpdateKeys.retryAfter);
      if (retryAt != null && retryAt.isAfter(_now())) {
        _queueRetry(retryAt);
      } else {
        unawaited(checkAutomatically());
      }
    }
  }

  /// Can also be called by settings UI tests that use a dynamic callback
  /// instead of an [AppSettings] listener.
  void automaticSettingChanged() => _onAutoSettingsChanged();

  /// Hides the app-level prompt for the rest of this app launch. The Updates
  /// screen continues to offer installation.
  void snoozeReadyPrompt() {
    if (_readyPromptSnoozed) return;
    _readyPromptSnoozed = true;
    notifyListeners();
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
      if (outcome.updated) {
        store.write(UpdateKeys.readyRecord, null);
        await cleanUpdateDir(info.updateDir);
      }
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

  /// Restores a previously verified artifact after rechecking its signed
  /// manifest, expiry, replay ordering, installed version, bytes and platform
  /// identity. Invalid saved state is discarded fail-closed.
  Future<bool> restoreReady() async {
    if (_disposed) return false;
    final raw = store.read(UpdateKeys.readyRecord);
    if (raw == null) return false;
    try {
      final info = await installer.prepare();
      _info = info;
      final decoded = await _decodeReadyRecord(raw, info);
      final ready = ReadyUpdate(decoded.candidate, decoded.file);
      await _verifyReady(ready, info, proof: decoded.proof);
      _ready = ready;
      _proof = decoded.proof;
      _lastCandidate = decoded.candidate;
      _readyPromptSnoozed = false;
      await cleanUpdateDir(
        info.updateDir,
        keep: decoded.candidate.artifact.filename,
      );
      _set(UpdateReadyToInstall(decoded.candidate));
      return true;
    } on UpdateVerificationFailure catch (e) {
      store.write(UpdateKeys.readyRecord, null);
      final info = _info;
      if (info != null) await cleanUpdateDir(info.updateDir);
      _set(UpdateVerificationFailed(e.reason));
      return false;
    } on Object catch (e) {
      store.write(UpdateKeys.readyRecord, null);
      final info = _info;
      if (info != null) await cleanUpdateDir(info.updateDir);
      _set(UpdateVerificationFailed(_describe(e)));
      return false;
    }
  }

  Future<_RestoredReady> _decodeReadyRecord(
    String raw,
    InstallerInfo info,
  ) async {
    if (raw.length > 160 * 1024) {
      throw const UpdateVerificationFailure(
        'Saved update information is too large.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const UpdateVerificationFailure(
        'Saved update information is invalid.',
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['schema'] != 1 ||
        decoded['version'] is! String ||
        decoded['manifest'] is! String ||
        decoded['signature'] is! String ||
        decoded['assetUrl'] is! String ||
        decoded['notes'] is! String ||
        decoded['filename'] is! String) {
      throw const UpdateVerificationFailure(
        'Saved update information is invalid.',
      );
    }
    final Uint8List manifestBytes;
    final Uint8List signatureBytes;
    try {
      manifestBytes = base64Decode(decoded['manifest'] as String);
      signatureBytes = base64Decode(decoded['signature'] as String);
    } on FormatException {
      throw const UpdateVerificationFailure(
        'Saved update information is invalid.',
      );
    }
    if (manifestBytes.length > kMaxManifestBytes ||
        signatureBytes.length > kMaxSignatureBytes) {
      throw const UpdateVerificationFailure(
        'Saved update information is too large.',
      );
    }
    final expectedVersion = decoded['version'] as String;
    final VerifiedManifest verified;
    try {
      verified = await verifyManifest(
        manifestBytes: manifestBytes,
        signatureBytes: signatureBytes,
        keys: keys,
        expectedVersion: expectedVersion,
        now: _now(),
      );
    } on ManifestException catch (e) {
      throw UpdateVerificationFailure(e.message);
    }
    final manifest = verified.manifest;
    final artifact = manifest.artifactFor(
      info.platform.name,
      info.platform.arch,
    );
    final filename = decoded['filename'] as String;
    if (artifact == null || artifact.filename != filename) {
      throw const UpdateVerificationFailure(
        'The saved update does not match this device.',
      );
    }
    if (!_isAtLeastHighest(manifest)) {
      throw const UpdateVerificationFailure(
        'This release is older than one Notes has already verified.',
      );
    }
    if (!_isNewer(info, manifest, artifact)) {
      throw const UpdateVerificationFailure(
        'The saved update is no longer newer than this installation.',
      );
    }
    final url = Uri.tryParse(decoded['assetUrl'] as String);
    if (decoded['assetUrl'].toString().length > 4096 ||
        url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty) {
      throw const UpdateVerificationFailure(
        'The saved update download address is invalid.',
      );
    }
    final notes = decoded['notes'] as String;
    if (notes.length > kMaxReleaseNotesChars) {
      throw const UpdateVerificationFailure(
        'Saved release notes are too large.',
      );
    }
    final release = GithubRelease(
      tag: 'v${manifest.version}',
      version: manifest.version,
      notes: notes,
      assets: [
        GithubAsset(
          name: artifact.filename,
          size: artifact.size,
          downloadUrl: url,
        ),
      ],
    );
    final candidate = UpdateCandidate(
      release: release,
      manifest: manifest,
      artifact: artifact,
      assetUrl: url,
      signed: verified.signed,
      platform: info.platform,
    );
    final block = _blockFor(candidate, info);
    if (block != null) throw UpdateVerificationFailure(block.message);
    final file = File('${info.updateDir.path}/${artifact.filename}');
    return _RestoredReady(
      candidate,
      file,
      _ReadyProof(
        manifestBytes: manifestBytes,
        signatureBytes: signatureBytes,
        notes: notes,
        assetUrl: url,
      ),
    );
  }

  // Checking -----------------------------------------------------------------

  /// Asks GitHub for the latest stable release and decides what it means.
  /// [manual] only documents the caller; both paths behave the same.
  Future<void> check({bool manual = true}) async {
    if (busy || _disposed) return;
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
          _recordFailure(retryAt: resetAt);
          _set(UpdateRateLimited(resetAt));
        case ReleaseOffline():
          _recordFailure();
          _set(const UpdateOffline());
        case ReleaseFailed(:final message):
          _recordFailure();
          _set(UpdateFailed(message));
        case ReleaseNotModified():
          _recordFailure();
          _set(const UpdateFailed('GitHub sent an unexpected answer.'));
        case ReleaseFetched(:final release):
          store.write(UpdateKeys.retryAfter, null);
          await _evaluate(release, info, automatic: !manual);
          if (_status is UpdateFailed || _status is UpdateVerificationFailed) {
            _recordFailure();
          }
      }
    } on TimeoutException {
      _recordFailure();
      _set(const UpdateFailed('GitHub did not answer in time.'));
    } on UpdateOfflineException {
      _recordFailure();
      _set(const UpdateOffline());
    } on SocketException {
      _recordFailure();
      _set(const UpdateOffline());
    } on ManifestException catch (e) {
      _recordFailure();
      _set(UpdateVerificationFailed(e.message));
    } on Object catch (e) {
      _recordFailure();
      _set(UpdateFailed(_describe(e)));
    }
  }

  void _concluded() {
    store.write(UpdateKeys.lastCheck, _now().toUtc().toIso8601String());
    store.write(UpdateKeys.failureCount, null);
    store.write(UpdateKeys.retryAfter, null);
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _recordFailure({DateTime? retryAt}) {
    final old = int.tryParse(store.read(UpdateKeys.failureCount) ?? '') ?? 0;
    final count = (old + 1).clamp(1, 16);
    store.write(UpdateKeys.failureCount, '$count');
    final multiplier = 1 << (count - 1).clamp(0, 12);
    final exponential = retryBaseDelay * multiplier;
    final delay = exponential > maxRetryDelay ? maxRetryDelay : exponential;
    final fallback = _now().add(delay);
    final until = retryAt != null && retryAt.isAfter(fallback)
        ? retryAt
        : fallback;
    store.write(UpdateKeys.retryAfter, until.toUtc().toIso8601String());
    if (_startupScheduled && autoCheckEnabled() && !devInstance) {
      _queueRetry(until);
    }
  }

  void _queueRetry(DateTime retryAt) {
    _retryTimer?.cancel();
    final delay = retryAt.difference(_now());
    if (delay <= Duration.zero || _disposed) return;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(checkAutomatically());
    });
  }

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

  Future<void> _evaluate(
    GithubRelease release,
    InstallerInfo info, {
    required bool automatic,
  }) async {
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
    _proof = _ReadyProof(
      manifestBytes: manifestBytes,
      signatureBytes: sig,
      notes: release.notes,
      assetUrl: asset.downloadUrl,
    );
    final block = _blockFor(candidate, info);
    if (block != null) {
      _set(UpdateBlocked(block, candidate: candidate));
      return;
    }
    _set(UpdateAvailable(candidate));
    if (automatic && autoCheckEnabled()) await download(automatic: true);
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

  /// Downloads and verifies the update found by the last check. Automatic
  /// downloads run in the background; manual downloads remain available while
  /// automatic updates are off.
  Future<void> download({bool automatic = false}) async {
    final candidate = switch (_status) {
      UpdateAvailable(:final candidate) => candidate,
      UpdateFailed(:final candidate?) => candidate,
      UpdateOffline(:final candidate?) => candidate,
      UpdateDownloadPaused(:final candidate) => candidate,
      UpdateVerificationFailed() => _lastCandidate,
      _ => null,
    };
    if (candidate == null || busy || (automatic && !autoCheckEnabled())) return;
    _lastCandidate = candidate;
    _ready = null;
    _automaticDownload = automatic;
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
        releaseVersion: candidate.version,
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
        store.write(UpdateKeys.readyRecord, null);
        _set(UpdateVerificationFailed(e.reason));
        return;
      }
      await cleanUpdateDir(info.updateDir, keep: candidate.artifact.filename);
      final proof = _proof;
      if (proof == null) {
        await _deleteQuietly(file);
        throw const UpdateVerificationFailure(
          'The signed release details are no longer available.',
        );
      }
      store.write(UpdateKeys.readyRecord, _encodeReadyRecord(candidate, proof));
      _ready = ready;
      _set(UpdateReadyToInstall(candidate));
    } on DownloadException catch (e) {
      if (automatic && e.kind != DownloadFailure.cancelled) _recordFailure();
      switch (e.kind) {
        case DownloadFailure.cancelled:
          _set(
            UpdateDownloadPaused(
              candidate,
              await _partialLength(candidate),
              candidate.size,
            ),
          );
        case DownloadFailure.offline:
          _set(UpdateOffline(candidate: candidate));
        case DownloadFailure.sizeMismatch:
        case DownloadFailure.checksumMismatch:
          _set(UpdateVerificationFailed(e.message));
        case DownloadFailure.interrupted:
          _set(
            UpdateDownloadPaused(
              candidate,
              await _partialLength(candidate),
              candidate.size,
            ),
          );
        case DownloadFailure.http:
        case DownloadFailure.contentType:
        case DownloadFailure.diskSpace:
        case DownloadFailure.permission:
        case DownloadFailure.unsafeName:
          _set(UpdateFailed(e.message, candidate: candidate));
      }
    } on UpdateVerificationFailure catch (e) {
      if (automatic) _recordFailure();
      store.write(UpdateKeys.readyRecord, null);
      _set(UpdateVerificationFailed(e.reason));
    } on Object catch (e) {
      if (automatic) _recordFailure();
      _set(UpdateFailed(_describe(e), candidate: candidate));
    } finally {
      if (identical(_cancel, token)) _cancel = null;
      _automaticDownload = false;
    }
  }

  UpdateCandidate? _lastCandidate;

  /// Cancels a running download. Its manifest-bound partial file can resume.
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
      final info = await installer.prepare();
      _info = info;
      final raw = store.read(UpdateKeys.readyRecord);
      if (raw == null) {
        throw const UpdateVerificationFailure(
          'The verified update record is missing. Check for updates again.',
        );
      }
      final decoded = await _decodeReadyRecord(raw, info);
      if (!_sameCandidate(candidate, decoded.candidate) ||
          decoded.file.path != ready.file.path) {
        throw const UpdateVerificationFailure(
          'The saved update no longer matches this download.',
        );
      }
      await _verifyReady(ready, info, proof: decoded.proof);
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
    } on UpdateVerificationFailure catch (e) {
      store.write(UpdateKeys.readyRecord, null);
      await _deleteQuietly(ready.file);
      _ready = null;
      _set(UpdateVerificationFailed(e.reason));
    } on Object catch (e) {
      _set(UpdateReadyToInstall(candidate, message: _describe(e)));
    }
  }

  /// Android: opens the system page that lets Notes install updates. The user
  /// returns and presses Install again; nothing retries by itself.
  Future<void> openInstallSettings() => installer.openInstallSettings();

  // Helpers ------------------------------------------------------------------

  String _encodeReadyRecord(UpdateCandidate candidate, _ReadyProof proof) {
    final signature = proof.signatureBytes;
    if (signature == null) {
      throw const UpdateVerificationFailure(
        'The release signature is missing.',
      );
    }
    return jsonEncode({
      'schema': 1,
      'version': candidate.version,
      'filename': candidate.artifact.filename,
      'manifest': base64Encode(proof.manifestBytes),
      'signature': base64Encode(signature),
      'assetUrl': proof.assetUrl.toString(),
      'notes': proof.notes,
    });
  }

  Future<void> _verifyReady(
    ReadyUpdate ready,
    InstallerInfo info, {
    required _ReadyProof proof,
  }) async {
    final candidate = ready.candidate;
    final signature = proof.signatureBytes;
    if (signature == null) {
      throw const UpdateVerificationFailure(
        'The release signature is missing.',
      );
    }
    final VerifiedManifest verified;
    try {
      verified = await verifyManifest(
        manifestBytes: proof.manifestBytes,
        signatureBytes: signature,
        keys: keys,
        expectedVersion: candidate.version,
        now: _now(),
      );
    } on ManifestException catch (e) {
      throw UpdateVerificationFailure(e.message);
    }
    final manifest = verified.manifest;
    final artifact = manifest.artifactFor(
      info.platform.name,
      info.platform.arch,
    );
    if (!verified.signed ||
        artifact == null ||
        !_sameArtifact(artifact, candidate.artifact) ||
        manifest.buildNumber != candidate.manifest.buildNumber ||
        proof.assetUrl != candidate.assetUrl ||
        candidate.platform.os != info.platform.os ||
        candidate.platform.arch != info.platform.arch) {
      throw const UpdateVerificationFailure(
        'The signed update details do not match this download.',
      );
    }
    if (!_isAtLeastHighest(manifest)) {
      throw const UpdateVerificationFailure(
        'This release is older than one Notes has already verified.',
      );
    }
    if (!_isNewer(info, manifest, artifact)) {
      throw const UpdateVerificationFailure(
        'This update is no longer newer than the installed version.',
      );
    }
    if (!await ready.file.exists() ||
        await ready.file.length() != artifact.size) {
      throw const UpdateVerificationFailure(
        'The downloaded update is missing or has changed size.',
      );
    }
    final digest = await sha256.bind(ready.file.openRead()).first;
    if (digest.toString() != artifact.sha256) {
      throw const UpdateVerificationFailure(
        'The downloaded update has changed since it was verified.',
      );
    }
    try {
      await installer.verifyDownloaded(ready, info);
    } on UpdateVerificationFailure {
      rethrow;
    }
  }

  bool _isAtLeastHighest(UpdateManifest manifest) {
    final highestVersion = store.read(UpdateKeys.highestVersion);
    final highestBuild = int.tryParse(
      store.read(UpdateKeys.highestBuild) ?? '',
    );
    if (highestVersion == null && highestBuild == null) return true;
    if (highestVersion == null || highestBuild == null) return false;
    return compareReleases(
          manifest.version,
          manifest.buildNumber,
          highestVersion,
          highestBuild,
        ) >=
        0;
  }

  bool _isNewer(
    InstallerInfo info,
    UpdateManifest manifest,
    ManifestArtifact artifact,
  ) => switch (info.platform.os) {
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

  bool _sameArtifact(ManifestArtifact a, ManifestArtifact b) =>
      a.platform == b.platform &&
      a.arch == b.arch &&
      a.filename == b.filename &&
      a.sha256 == b.sha256 &&
      a.size == b.size &&
      a.versionCode == b.versionCode &&
      a.certSha256 == b.certSha256;

  bool _sameCandidate(UpdateCandidate a, UpdateCandidate b) =>
      a.version == b.version &&
      a.manifest.buildNumber == b.manifest.buildNumber &&
      a.assetUrl == b.assetUrl &&
      _sameArtifact(a.artifact, b.artifact);

  Future<int> _partialLength(UpdateCandidate candidate) async {
    try {
      final info = _info ?? await installer.prepare();
      final file = File(
        '${info.updateDir.path}/${candidate.artifact.filename}.part',
      );
      return await file.exists() ? await file.length() : 0;
    } on Object {
      return 0;
    }
  }

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

class _ReadyProof {
  const _ReadyProof({
    required this.manifestBytes,
    required this.signatureBytes,
    required this.notes,
    required this.assetUrl,
  });

  final Uint8List manifestBytes;
  final Uint8List? signatureBytes;
  final String notes;
  final Uri assetUrl;
}

class _RestoredReady {
  const _RestoredReady(this.candidate, this.file, this.proof);

  final UpdateCandidate candidate;
  final File file;
  final _ReadyProof proof;
}
