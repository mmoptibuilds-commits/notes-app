/// The one place the app learns its own version. `test/core/app_version_test.dart`
/// checks it against `pubspec.yaml`, so a release bump cannot leave them apart.
const appVersionName = '1.2.0';

/// Android versionCode / the pubspec build number. Strictly increasing.
const appBuildNumber = 20261125;

/// The version shown in the UI.
const appVersionText = appVersionName;
