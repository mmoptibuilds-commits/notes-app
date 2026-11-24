import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_config.dart';

void main() {
  const defaultUrl = 'https://notes-sync.example.invalid';
  String resolve(Map<String, String> env, [String compiled = '']) =>
      resolveCloudUrl(
        environment: env,
        compiledUrl: compiled,
        defaultUrl: defaultUrl,
      );

  test('a normal installation uses the default server', () {
    expect(resolve({}), defaultUrl);
  });

  test('the environment variable beats the compile-time define', () {
    expect(
      resolve({
        'NOTES_CLOUD_URL': 'https://env.example.invalid',
      }, 'https://def.example.invalid'),
      'https://env.example.invalid',
    );
    expect(
      resolve({}, 'https://def.example.invalid'),
      'https://def.example.invalid',
    );
  });

  test('a development instance never reaches the default server', () {
    expect(resolve({'NOTES_DATA_DIR': '/tmp/x'}), '');
    expect(
      resolve({
        'NOTES_DATA_DIR': '/tmp/x',
        'NOTES_CLOUD_URL': 'https://t.example.invalid',
      }),
      'https://t.example.invalid',
    );
  });

  test(
    'the file session store keeps its own session and can be cleared',
    () async {
      final dir = await Directory.systemTemp.createTemp('notes-cloud-session-');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileCloudSessionStore(dir.path);
      expect(await store.read(), isNull);
      await store.write(
        const CloudSession(
          deviceId: 'd',
          access: 'a',
          accessExp: 1,
          refresh: 'r',
        ),
      );
      expect((await store.read())?.deviceId, 'd');
      await store.write(null);
      expect(await store.read(), isNull);
    },
  );
}
