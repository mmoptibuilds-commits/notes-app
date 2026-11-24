/// The one place the app learns its own version. `test/core/app_version_test.dart`
/// checks it against `pubspec.yaml`, so a release bump cannot leave them apart.
const appVersionName = '1.3.0';

/// Android versionCode / the pubspec build number. Strictly increasing.
const appBuildNumber = 20261126;

/// The version shown in the UI.
const appVersionText = appVersionName;
