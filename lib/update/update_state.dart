import 'package:sqlite3/sqlite3.dart';

import '../data/app_settings.dart';
import 'version_compare.dart';

/// Small persistent bookkeeping for the updater (last check, ETag, highest
/// verified release). Backed by app settings but written silently: these
/// values are shown nowhere that listens to settings, and a notification
/// would rebuild the whole app.
abstract class UpdateStateStore {
  String? read(String key);

  /// Throws [UpdateStateWriteException] if the write cannot be persisted.
  void write(String key, String? value);

  /// Whether [version] and [build] are at least the persisted replay mark.
  bool replayMarkAllows(String version, int build);

  /// Atomically rejects rollback and advances the persisted replay mark.
  bool advanceReplayMark(String version, int build);
}

class UpdateStateWriteException implements Exception {
  const UpdateStateWriteException();
}

class AppSettingsUpdateStore implements UpdateStateStore {
  AppSettingsUpdateStore(this._settings);
  final AppSettings _settings;

  @override
  String? read(String key) => _settings.read(key);

  @override
  void write(String key, String? value) {
    try {
      _settings.writeSilently(key, value);
    } on SqliteException {
      throw const UpdateStateWriteException();
    } on StateError {
      throw const UpdateStateWriteException();
    }
  }

  @override
  bool replayMarkAllows(String version, int build) {
    try {
      final mark = _settings.readSilentlyBatch(const [
        UpdateKeys.highestVersion,
        UpdateKeys.highestBuild,
      ]);
      final highestVersion = mark[UpdateKeys.highestVersion];
      final highestBuild = int.tryParse(mark[UpdateKeys.highestBuild] ?? '');
      if (highestVersion == null && highestBuild == null) return true;
      if (highestVersion == null || highestBuild == null) return false;
      return compareReleases(version, build, highestVersion, highestBuild) >= 0;
    } on SqliteException {
      throw const UpdateStateWriteException();
    } on StateError {
      throw const UpdateStateWriteException();
    }
  }

  @override
  bool advanceReplayMark(String version, int build) {
    try {
      return _settings.writeSilentlyBatchIf(
        values: {
          UpdateKeys.highestVersion: version,
          UpdateKeys.highestBuild: '$build',
        },
        shouldWrite: (mark) {
          final highestVersion = mark[UpdateKeys.highestVersion];
          final highestBuild = int.tryParse(
            mark[UpdateKeys.highestBuild] ?? '',
          );
          if (highestVersion == null || highestBuild == null) return true;
          return compareReleases(
                version,
                build,
                highestVersion,
                highestBuild,
              ) >=
              0;
        },
      );
    } on SqliteException {
      throw const UpdateStateWriteException();
    } on StateError {
      throw const UpdateStateWriteException();
    }
  }
}

class MemoryUpdateStore implements UpdateStateStore {
  final values = <String, String>{};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String? value) {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  bool replayMarkAllows(String version, int build) {
    final highestVersion = read(UpdateKeys.highestVersion);
    final highestBuild = int.tryParse(read(UpdateKeys.highestBuild) ?? '');
    if (highestVersion == null && highestBuild == null) return true;
    if (highestVersion == null || highestBuild == null) return false;
    return compareReleases(version, build, highestVersion, highestBuild) >= 0;
  }

  @override
  bool advanceReplayMark(String version, int build) {
    final highestVersion = read(UpdateKeys.highestVersion);
    final highestBuild = int.tryParse(read(UpdateKeys.highestBuild) ?? '');
    if (highestVersion != null &&
        highestBuild != null &&
        compareReleases(version, build, highestVersion, highestBuild) < 0) {
      return false;
    }
    values[UpdateKeys.highestVersion] = version;
    values[UpdateKeys.highestBuild] = '$build';
    return true;
  }
}

/// Setting keys owned by the updater.
abstract final class UpdateKeys {
  static const lastAttempt = 'update.lastAttempt';
  static const lastCheck = 'update.lastCheck';
  static const retryAfter = 'update.retryAfter';
  static const etag = 'update.etag';
  static const cachedRelease = 'update.cachedRelease';
  static const highestVersion = 'update.highestVersion';
  static const highestBuild = 'update.highestBuild';
  static const ackedOutcome = 'update.ackedOutcome';
  static const failureCount = 'update.failureCount';
  static const readyRecord = 'update.readyRecord';
}
