import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('com.mmoptibuilds.notes/save');

/// `file_selector` has no save dialog on Android, so there the file goes
/// through the system document picker (see MainActivity.kt).
bool get usesNativeSavePicker =>
    defaultTargetPlatform == TargetPlatform.android;

/// Lets the user pick where to create [name] and writes [bytes] there. Returns
/// the saved file's display name, or null if the user cancelled. Throws a
/// [PlatformException] if there is no picker or the write fails.
Future<String?> saveBytesWithPicker({
  required String name,
  required String mime,
  required Uint8List bytes,
}) => _channel.invokeMethod<String>('saveFile', {
  'name': name,
  'mime': mime,
  'bytes': bytes,
});
