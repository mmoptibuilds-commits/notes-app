import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/cloud_login.dart';
import 'package:notes/platform/cloud_login_linux.dart';

void main() {
  late LinuxCloudLoginLauncher launcher;
  late Completer<String> opened;

  setUp(() {
    opened = Completer<String>();
    launcher = LinuxCloudLoginLauncher(
      processRunner: (_, args) async {
        opened.complete(args.single);
      },
    );
  });

  Future<HttpClientResponse> request(
    Uri uri, {
    String method = 'GET',
    String? path,
  }) async {
    final client = HttpClient();
    final req = await client.openUrl(
      method,
      uri.replace(path: path ?? uri.path),
    );
    final response = await req.close();
    client.close(force: true);
    return response;
  }

  test('round trips code and state and serves return page once', () async {
    final resultFuture = launcher.login((redirect) {
      expect(redirect, startsWith('http://127.0.0.1:'));
      return Uri.parse('https://example.invalid/start?redirect=$redirect');
    });
    final uri = Uri.parse(await opened.future).queryParameters['redirect']!;
    final callback = Uri.parse(uri)
        .replace(queryParameters: {'code': 'fake-code', 'state': 'fake-state'});
    final response = await request(callback);
    expect(response.statusCode, HttpStatus.ok);
    expect(
      await response.transform(SystemEncoding().decoder).join(),
      contains('You can return to Notes.'),
    );
    final result = await resultFuture;
    expect(result.code, 'fake-code');
    expect(result.state, 'fake-state');
  });

  test('wrong path is 404 and login remains available', () async {
    final result = launcher.login(
      (redirect) => Uri.parse('https://example.invalid/?redirect=$redirect'),
    );
    final uri = Uri.parse(await opened.future).queryParameters['redirect']!;
    expect(
      (await request(Uri.parse(uri), path: '/wrong')).statusCode,
      HttpStatus.notFound,
    );
    launcher.cancel();
    await expectLater(result, throwsA(isA<CloudLoginCancelled>()));
  });

  test('wrong method is refused', () async {
    final result = launcher.login(
      (redirect) => Uri.parse('https://example.invalid/?redirect=$redirect'),
    );
    final uri = Uri.parse(await opened.future).queryParameters['redirect']!;
    expect(
      (await request(Uri.parse(uri), method: 'POST')).statusCode,
      HttpStatus.methodNotAllowed,
    );
    launcher.cancel();
    await expectLater(result, throwsA(isA<CloudLoginCancelled>()));
  });

  test('error parameter fails without exposing its value', () async {
    final result = launcher.login(
      (redirect) => Uri.parse('https://example.invalid/?redirect=$redirect'),
    );
    final uri = Uri.parse(await opened.future).queryParameters['redirect']!;
    final expectation = expectLater(
      result,
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          isNot(contains('secret-error')),
        ),
      ),
    );
    await request(
      Uri.parse(uri).replace(queryParameters: {'error': 'secret-error'}),
    );
    await expectation;
  });

  test(
    'timeout and cancel close the listener; second callback is unavailable',
    () async {
      final timed = launcher.login(
        (redirect) => Uri.parse('https://example.invalid/?redirect=$redirect'),
        timeout: const Duration(milliseconds: 10),
      );
      await opened.future;
      await expectLater(timed, throwsA(isA<CloudLoginTimeout>()));
      opened = Completer<String>();
      final cancelled = launcher.login(
        (redirect) => Uri.parse('https://example.invalid/?redirect=$redirect'),
      );
      final uri = Uri.parse(await opened.future).queryParameters['redirect']!;
      final callback = Uri.parse(uri)
          .replace(queryParameters: {'code': 'once', 'state': 's'});
      await request(callback);
      await cancelled;
      await expectLater(request(callback), throwsA(isA<SocketException>()));
    },
  );
}
