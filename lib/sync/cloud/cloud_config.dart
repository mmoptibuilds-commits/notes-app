import 'dart:convert';
import 'dart:io';

import 'cloud_api.dart';

/// The private cloud sync server of this installation. The address is public
/// and not a secret; every request still needs a session that only the owner's
/// verified Google account can obtain. Release builds can override it with
/// `--dart-define=NOTES_CLOUD_URL=...` (an empty define keeps the default).
const kDefaultCloudUrl = 'https://notes-sync.mmoptibuilds.workers.dev';

/// Decides which server this process talks to, or `''` when cloud sync is
/// unavailable.
///
/// Order: the `NOTES_CLOUD_URL` environment variable (any platform where it is
/// set, mainly Linux), then the compile-time define, then the default. A
/// development instance (`NOTES_DATA_DIR` set) never falls back to the default:
/// experiments must not reach the owner's real library, so it needs an explicit
/// address.
String resolveCloudUrl({
  required Map<String, String> environment,
  required String compiledUrl,
  String defaultUrl = kDefaultCloudUrl,
}) {
  final fromEnvironment = environment['NOTES_CLOUD_URL'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    return fromEnvironment;
  }
  if (compiledUrl.isNotEmpty) return compiledUrl;
  final devInstance = (environment['NOTES_DATA_DIR'] ?? '').isNotEmpty;
  return devInstance ? '' : defaultUrl;
}

/// Session storage for development instances (`NOTES_DATA_DIR`): a plain file
/// inside that instance's own directory. It must never share the system key
/// store with the real app, or signing in from an experiment would replace the
/// real session.
class FileCloudSessionStore implements CloudSessionStore {
  FileCloudSessionStore(String dir) : _file = File('$dir/cloud-session.json');
  final File _file;

  @override
  Future<CloudSession?> read() async {
    try {
      if (!await _file.exists()) return null;
      final text = await _file.readAsString();
      return CloudSession.fromJson(
        (_decode(text) as Map).cast<String, Object?>(),
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(CloudSession? session) async {
    if (session == null) {
      if (await _file.exists()) await _file.delete();
      return;
    }
    await _file.parent.create(recursive: true);
    await _file.writeAsString(_encode(session.toJson()), flush: true);
  }
}

Object? _decode(String text) => jsonDecode(text);
String _encode(Object? value) => jsonEncode(value);
