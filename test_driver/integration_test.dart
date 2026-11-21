// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  await integrationDriver(
    driver: driver,
    writeResponseOnFailure: true,
    onScreenshot: (String name, List<int> bytes, [
      Map<String, Object?>? args,
    ]) async {
      final file = File('build/screens/android/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      // ignore: avoid_print
      print('Wrote Android screenshot: ${file.path}');
      return true;
    },
  );
  await driver.close();
}
