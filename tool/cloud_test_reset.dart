// Resets the library of an isolated TEST Worker (fake sign-in, test bundle
// only). Run before both device roles start so neither can see a stale library.
//   dart run tool/cloud_test_reset.dart <worker-url>
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/cloud_test_reset.dart <worker-url>');
    exit(2);
  }
  await resetCloudTestLibrary(Uri.parse(args.single));
  stdout.writeln('Test library reset.');
}

Future<void> resetCloudTestLibrary(Uri worker) async {
  final rnd = Random.secure();
  String rand(int n) => base64Url
      .encode(List.generate(n, (_) => rnd.nextInt(256)))
      .replaceAll('=', '');
  final verifier = rand(32);
  final state = rand(24);
  final challenge = base64Url
      .encode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');
  final client = HttpClient();
  try {
    Future<String> text(HttpClientRequest req) async {
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('${req.uri.path} failed (${res.statusCode})');
      }
      return body;
    }

    String href(String page, String needle) {
      final m = RegExp('href="([^"]*$needle[^"]*)"').firstMatch(page);
      if (m == null) throw StateError('test sign-in page not found');
      return m.group(1)!.replaceAll('&amp;', '&');
    }

    final start = await text(
      await client.getUrl(
        worker
            .resolve('/v1/auth/start')
            .replace(
              queryParameters: {
                'challenge': challenge,
                'redirect': 'http://127.0.0.1:43721/cb',
                'state': state,
                'name': 'Reset helper',
              },
            ),
      ),
    );
    final signed = await text(
      await client.getUrl(worker.resolve(href(start, 'account=owner'))),
    );
    final code = Uri.parse(href(signed, 'code=')).queryParameters['code']!;
    Future<Map<String, Object?>> post(
      String path,
      Object body, [
      String? token,
    ]) async {
      final req = await client.postUrl(worker.resolve(path));
      req.headers.contentType = ContentType.json;
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      req.write(jsonEncode(body));
      final out = await text(req);
      return out.isEmpty ? {} : jsonDecode(out) as Map<String, Object?>;
    }

    final session = await post('/v1/auth/token', {
      'code': code,
      'verifier': verifier,
    });
    final access = session['access']! as String;
    try {
      await post('/v1/test/reset', const {}, access);
    } finally {
      await post('/v1/auth/logout', const {}, access); // frees the device slot
    }
  } finally {
    client.close(force: true);
  }
}
