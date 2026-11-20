/// Check that a stable release advances Android versionCode.
///
/// Usage: `dart tool/check_stable_version.dart --stable [--previous <code>]`
/// The default previous code comes from `tool/last_release_version_code.txt`.
/// This script reads the version string from `pubspec.yaml` and does not edit it.
library;

import 'dart:io';

int versionCodeFromPubspec(String pubspec) {
  final match = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec);
  if (match == null) {
    throw const FormatException('pubspec.yaml has no version field.');
  }
  final version = match.group(1)!;
  final buildNumber = version.split('+');
  if (buildNumber.length != 2 || buildNumber.last.isEmpty) {
    throw const FormatException(
      'pubspec.yaml version must include a numeric build number after + for a stable release.',
    );
  }
  final parsed = int.tryParse(buildNumber.last);
  if (parsed == null || parsed <= 0) {
    throw const FormatException(
      'pubspec.yaml build number must be a positive integer.',
    );
  }
  return parsed;
}

int parsePreviousVersionCode(String value) {
  final values = value
      .split('\n')
      .map((line) => line.split('#').first.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final parsed = values.length == 1 ? int.tryParse(values.single) : null;
  if (parsed == null || parsed <= 0) {
    throw const FormatException(
      'Previous versionCode must be a positive integer.',
    );
  }
  return parsed;
}

void validateStableVersionCode(int newVersionCode, int previousVersionCode) {
  if (newVersionCode <= previousVersionCode) {
    throw FormatException(
      'Stable release versionCode $newVersionCode must be greater than previous '
      'distributed versionCode $previousVersionCode.',
    );
  }
}

Future<void> main(List<String> args) async {
  try {
    var stable = false;
    String? previousOverride;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--stable' && !stable) {
        stable = true;
      } else if (args[i] == '--previous' &&
          previousOverride == null &&
          i + 1 < args.length) {
        previousOverride = args[++i];
      } else {
        throw const FormatException(
          'Usage: dart tool/check_stable_version.dart --stable [--previous <code>]',
        );
      }
    }
    if (!stable) {
      throw const FormatException(
        'Pass --stable to run the stable release version check.',
      );
    }
    final previous = previousOverride == null
        ? parsePreviousVersionCode(
            File('tool/last_release_version_code.txt').readAsStringSync(),
          )
        : parsePreviousVersionCode(previousOverride);
    final current = versionCodeFromPubspec(
      File('pubspec.yaml').readAsStringSync(),
    );
    validateStableVersionCode(current, previous);
    stdout.writeln(
      'Stable release versionCode $current advances previous code $previous.',
    );
  } on Object catch (error) {
    stderr.writeln('Stable release version check failed: $error');
    exitCode = 1;
  }
}
