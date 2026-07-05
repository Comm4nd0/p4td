import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/services/http_client.dart' as http;

/// Tests for [http.sendMultipart] against a real local HTTP server, covering
/// the failure modes that used to lose photos on slow phones/connections:
/// transient server errors, dead connections that never respond, and the
/// no-retry contract for permanent 4xx rejections.
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

  test('retries a transient 500 and succeeds on the next attempt', () async {
    handlers = [(request) => respond(request, 500, 'boom')];

    final response = await http.sendMultipart(
      method: 'POST',
      url: url,
      fill: fillRequest,
      retryDelays: const [Duration(milliseconds: 10)],
    );

    expect(response.statusCode, 201);
    expect(requestCount, 2);
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

  test('aborts a server that never replies, then retries and succeeds', () async {
    handlers = [
      (request) async {
        // Swallow the body and go silent — the watchdog must abort this.
        await request.drain<void>();
      },
    ];

    final response = await http.sendMultipart(
      method: 'POST',
      url: url,
      fill: fillRequest,
      stallTimeout: const Duration(milliseconds: 500),
      responseTimeout: const Duration(milliseconds: 300),
      retryDelays: const [Duration(milliseconds: 10)],
    );

    expect(response.statusCode, 201);
    expect(requestCount, 2);
  });

  test('throws a TimeoutException once attempts are exhausted', () async {
    Future<void> hang(HttpRequest request) => request.drain<void>();
    handlers = [hang, hang];

    await expectLater(
      http.sendMultipart(
        method: 'POST',
        url: url,
        fill: fillRequest,
        maxAttempts: 2,
        stallTimeout: const Duration(milliseconds: 500),
        responseTimeout: const Duration(milliseconds: 300),
        retryDelays: const [Duration(milliseconds: 10)],
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(requestCount, 2);
  });
}
