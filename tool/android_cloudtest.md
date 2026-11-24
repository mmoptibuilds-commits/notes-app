# Android cloud test build

Build an isolated Android release APK with:

```sh
tool/build_cloudtest_apk.sh --dart-define=NOTES_CLOUD_URL=https://example.invalid
```

The script selects JDK 21, sets the Gradle `cloudTest` property, and prints the
APK path, version name and code, application id, and signing certificate SHA-1.
Extra Flutter build arguments, including Dart defines, are passed through.
The test build uses the local Android debug keystore; it does not require
`android/key.properties`.

Its id is `com.mmoptibuilds.notes.cloudtest` and its redirect scheme is
`com.mmoptibuilds.notes.cloudtest:/cloud-auth`. Android treats it as a separate
application with separate app-private data. It never opens or changes data owned
by the production Notes app. Do not install this build on an owner's device
without approval.
