import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/platform/cloud_login_android.dart';

const channel = MethodChannel('com.mmoptibuilds.notes/cloudlogin');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('ignores a stale pending callback and completes only on a live one', () async {
    var consumed = 0;
    var opened = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumeInitialUri') {
        consumed++;
        return 'com.mmoptibuilds.notes:/cloud-auth?code=stale-code&state=stale-state';
      }
      if (call.method == 'redirectUri') {
        return 'com.mmoptibuilds.notes:/cloud-auth';
      }
      if (call.method == 'openUrl') {
        opened++;
      }
      return null;
    });
    final login = AndroidCloudLoginLauncher().login(
      (redirect) =>
          Uri.parse('https://example.invalid/start?redirect=$redirect'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(opened, 1);
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        const MethodCall(
          'authUri',
          'com.mmoptibuilds.notes:/cloud-auth?code=fake-code&state=fake-state',
        ),
      ),
      (_) {},
    );
    final result = await login;
    expect(result.code, 'fake-code');
    expect(result.state, 'fake-state');
    expect(consumed, 1);
  });

  test(
    'reports browser launch failure without exposing platform details',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'consumeInitialUri') {
          return null;
        }
        if (call.method == 'redirectUri') {
          return 'com.mmoptibuilds.notes:/cloud-auth';
        }
        throw PlatformException(
          code: 'no_browser',
          message: 'private browser detail',
        );
      });
      await expectLater(
        AndroidCloudLoginLauncher().login(
          (redirect) =>
              Uri.parse('https://example.invalid/start?redirect=$redirect'),
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('private browser detail')),
          ),
        ),
      );
    },
  );
}
