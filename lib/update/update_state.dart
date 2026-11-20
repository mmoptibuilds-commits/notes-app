import '../data/app_settings.dart';

/// Small persistent bookkeeping for the updater (last check, ETag, highest
/// verified release). Backed by app settings but written silently: these
/// values are shown nowhere that listens to settings, and a notification
/// would rebuild the whole app.
abstract class UpdateStateStore {
  String? read(String key);
  void write(String key, String? value);
}

class AppSettingsUpdateStore implements UpdateStateStore {
  AppSettingsUpdateStore(this._settings);
  final AppSettings _settings;

  @override
  String? read(String key) => _settings.read(key);

  @override
  void write(String key, String? value) => _settings.writeSilently(key, value);
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
}
