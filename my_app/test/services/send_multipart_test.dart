import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/services/http_client.dart' as http;

/// Tests for [http.sendMultipart] against a real local HTTP server.
///
/// The rule under test: an upload is sent again only while the server cannot
/// have it — the connection failed or stalled before the body finished, or
/// the server said it did not take the request (408/429/503). Once the whole
/// body has gone up, nothing is retried: a second copy of a feed post is a
/// second post, with a second push to every tagged dog's owner.
void main() {
  late HttpServer server;
  late Uri url;

  /// Per-request scripted handlers; requests beyond the list get a 201.
  late List<Future<void> Function(HttpRequest request)> handlers;
  late int requestCount;

  Future<void> respond(HttpRequest request, int status, [String body = '']) async {
    await request.drain<void>();
    request.response.statusCode = status;
    request.response.write(body);
    await request.response.close();
  }

  setUp(() async {
    handlers = [];
    requestCount = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('http://${server.address.host}:${server.port}/upload');
    server.listen((request) async {
      final index = requestCount++;
      if (index < handlers.length) {
        await handlers[index](request);
      } else {
        await respond(request, 201, '{"ok": true}');
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  void fillRequest(http.MultipartRequest request) {
    request.fields['media_type'] = 'PHOTO';
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      List<int>.filled(100 * 1024, 7),
      filename: 'photo.jpg',
    ));
  }

  test('uploads successfully and reports byte progress up to the total', () async {
    int? lastSent;
    int? lastTotal;
    final response = await http.sendMultipart(
      method: 'POST',
      url: url,
      fill: fillRequest,
      onProgress: (sent, total) {
        lastSent = sent;
        lastTotal = total;
      },
      retryDelays: const [],
    );

    expect(response.statusCode, 201);
    expect(requestCount, 1);
    expect(lastTotal, isNotNull);
    expect(lastSent, lastTotal);
  });

  test('retries a 503 (the server did not take it) and succeeds', () async {
    handlers = [(request) => respond(request, 503, 'busy')];

    final response = await http.sendMultipart(
      method: 'POST',
      url: url,
      fill: fillRequest,
      retryDelays: const [Duration(milliseconds: 10)],
    );

    expect(response.statusCode, 201);
    expect(requestCount, 2);
  });

  test('does not resend after a 500, 502 or 504 — the upload may have been saved', () async {
    for (final status in [500, 502, 504]) {
      requestCount = 0;
      handlers = [(request) => respond(request, status, 'boom')];

      final response = await http.sendMultipart(
        method: 'POST',
        url: url,
        fill: fillRequest,
        retryDelays: const [Duration(milliseconds: 10)],
      );

      expect(response.statusCode, status);
      expect(requestCount, 1, reason: '$status must reach the caller, not be retried');
    }
  });

  test('does not retry a permanent 400 rejection', () async {
    handlers = [(request) => respond(request, 400, '{"detail": "bad"}')];

    final response = await http.sendMultipart(
      method: 'POST',
      url: url,
      fill: fillRequest,
      retryDelays: const [Duration(milliseconds: 10)],
    );

    expect(response.statusCode, 400);
    expect(requestCount, 1);
  });

  test('a server that takes the whole body and never answers is not sent it twice', () async {
    handlers = [
      (request) async {
        // Swallow the body and go silent — as when the proxy's worker dies
        // after saving the row.
        await request.drain<void>();
      },
    ];

    await expectLater(
      http.sendMultipart(
        method: 'POST',
        url: url,
        fill: fillRequest,
        stallTimeout: const Duration(milliseconds: 500),
        responseTimeout: const Duration(milliseconds: 300),
        retryDelays: const [Duration(milliseconds: 10)],
      ),
      throwsA(isA<http.UploadUnconfirmedException>()),
    );
    expect(requestCount, 1);
  });

  test('a connection that never opens is retried, then reported as a network error', () async {
    // A port with nothing listening: no byte of the body can have arrived.
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadUrl = Uri.parse('http://${dead.address.host}:${dead.port}/upload');
    await dead.close(force: true);

    var attempts = 0;
    await expectLater(
      http.sendMultipart(
        method: 'POST',
        url: deadUrl,
        fill: (request) {
          attempts++;
          fillRequest(request);
        },
        maxAttempts: 3,
        retryDelays: const [Duration(milliseconds: 10)],
      ),
      throwsA(predicate((e) => e is! http.UploadUnconfirmedException)),
    );
    expect(attempts, 3);
  });

  test('an upload that stalls part-way is retried', () async {
    // Far more than the socket buffers hold, to a server that reads nothing:
    // the body stops flowing with most of it still on the phone.
    void fillLarge(http.MultipartRequest request) {
      request.files.add(http.chunkedMultipartFile(
        'file',
        Uint8List(48 * 1024 * 1024),
        filename: 'video.mp4',
      ));
    }

    handlers = [
      (request) => Future<void>.delayed(const Duration(seconds: 30)),
    ];

    final response = await http.sendMultipart(
      method: 'POST',
      url: url,
      fill: fillLarge,
      stallTimeout: const Duration(milliseconds: 400),
      responseTimeout: const Duration(seconds: 20),
      retryDelays: const [Duration(milliseconds: 10)],
    );

    expect(response.statusCode, 201);
    expect(requestCount, 2);
  });

  test('fill may be async, so a file can be streamed from disk', () async {
    final dir = await Directory.systemTemp.createTemp('p4td_upload_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/clip.mp4');
    await file.writeAsBytes(List<int>.filled(64 * 1024, 3));

    int? received;
    handlers = [
      (request) async {
        received = (await request.fold<int>(0, (n, chunk) => n + chunk.length));
        request.response.statusCode = 201;
        await request.response.close();
      },
    ];

    final response = await http.sendMultipart(
      method: 'POST',
      url: url,
      fill: (request) async {
        request.files.add(await http.MultipartFile.fromPath('file', file.path));
      },
      retryDelays: const [],
    );

    expect(response.statusCode, 201);
    expect(received, greaterThan(64 * 1024));
  });

  test('a 401 reports the token the upload was sent with', () async {
    handlers = [(request) => respond(request, 401, '{"detail": "Invalid token."}')];
    final rejected = <String?>[];
    http.onUnauthorized = rejected.add;
    addTearDown(() => http.onUnauthorized = null);

    await http.sendMultipart(
      method: 'POST',
      url: url,
      fill: (request) {
        request.headers['Authorization'] = 'Token abc123';
        fillRequest(request);
      },
      retryDelays: const [],
    );

    expect(rejected, ['abc123']);
  });

  test('tokenFromHeaders reads a token and treats anything else as anonymous', () {
    expect(http.tokenFromHeaders({'Authorization': 'Token abc'}), 'abc');
    expect(http.tokenFromHeaders({'authorization': 'Token abc'}), 'abc');
    expect(http.tokenFromHeaders({'Authorization': 'Token null'}), isNull);
    expect(http.tokenFromHeaders({'Authorization': 'Token '}), isNull);
    expect(http.tokenFromHeaders({'Content-Type': 'application/json'}), isNull);
    expect(http.tokenFromHeaders(null), isNull);
  });
}
