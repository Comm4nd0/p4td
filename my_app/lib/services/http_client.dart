import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'connectivity_status.dart';
import 'no_connection_exception.dart';

/// A drop-in replacement for the top-level functions of `package:http` that
/// logs each request/response in debug builds only.
///
/// Services import this `as http` instead of `package:http/http.dart`, so all
/// existing `http.get(...)`, `http.post(...)`, etc. calls are transparently
/// logged. All types (`http.Response`, `http.MultipartRequest`, ...) are
/// re-exported unchanged.
///
/// Only the method, URL path, status code and duration are logged — never
/// request bodies or headers, which can contain passwords and auth tokens.
export 'package:http/http.dart' hide get, post, put, patch, delete, head;

/// Default per-request timeout. Without one, a stalled mobile connection leaves
/// requests hanging forever — the UI spins and the offline/cache fallback never
/// fires because nothing throws (F2). A TimeoutException is treated as a network
/// error by [NoConnectionException.isNetworkError], so timing out also trips the
/// offline banner and stale-cache fallback.
const Duration _defaultTimeout = Duration(seconds: 30);

/// Invoked once when the server rejects the auth token (HTTP 401). Wired up in
/// main.dart to sign the user out and route to the login screen, so an
/// invalidated token doesn't leave the app permanently broken (F3). Note: 403
/// is NOT treated as an auth failure here — in this API it means "authenticated
/// but not permitted" (a role check), which must not log the user out.
void Function()? onUnauthorized;

Future<http.Response> _log(
  String method,
  Uri url,
  Future<http.Response> Function() send, {
  Duration timeout = _defaultTimeout,
}) async {
  final sw = Stopwatch()..start();
  try {
    final response = await send().timeout(timeout);
    sw.stop();
    // A response (even a 4xx/5xx) means the server is reachable.
    ConnectivityStatus().reportSuccess();
    if (kDebugMode) {
      debugPrint('[http] $method ${url.path} -> ${response.statusCode} '
          '(${sw.elapsedMilliseconds}ms)');
    }
    if (response.statusCode == 401) {
      onUnauthorized?.call();
    }
    return response;
  } catch (e) {
    sw.stop();
    if (NoConnectionException.isNetworkError(e)) {
      ConnectivityStatus().reportNetworkFailure();
    }
    if (kDebugMode) {
      debugPrint('[http] $method ${url.path} -> ERROR $e '
          '(${sw.elapsedMilliseconds}ms)');
    }
    rethrow;
  }
}

/// [timeout] lets read paths that have a cache fallback give up early instead
/// of holding the UI on the full default timeout.
Future<http.Response> get(Uri url,
        {Map<String, String>? headers, Duration timeout = _defaultTimeout}) =>
    _log('GET', url, () => http.get(url, headers: headers), timeout: timeout);

Future<http.Response> post(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _log('POST', url,
        () => http.post(url, headers: headers, body: body, encoding: encoding));

Future<http.Response> put(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _log('PUT', url,
        () => http.put(url, headers: headers, body: body, encoding: encoding));

Future<http.Response> patch(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _log('PATCH', url,
        () => http.patch(url, headers: headers, body: body, encoding: encoding));

Future<http.Response> delete(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _log('DELETE', url,
        () => http.delete(url, headers: headers, body: body, encoding: encoding));

Future<http.Response> head(Uri url,
        {Map<String, String>? headers, Duration timeout = _defaultTimeout}) =>
    _log('HEAD', url, () => http.head(url, headers: headers), timeout: timeout);

/// A [http.MultipartRequest] that reports how many body bytes have been
/// handed to the HTTP client. The socket applies backpressure, so this tracks
/// real upload progress closely enough to drive a stall watchdog and a
/// progress bar.
class _ProgressMultipartRequest extends http.MultipartRequest {
  _ProgressMultipartRequest(super.method, super.url);

  void Function(int sent, int total)? onChunk;

  @override
  http.ByteStream finalize() {
    final total = contentLength;
    var sent = 0;
    return http.ByteStream(super.finalize().map((chunk) {
      sent += chunk.length;
      onChunk?.call(sent, total);
      return chunk;
    }));
  }
}

/// Sends a multipart request (media upload) with stall detection and bounded
/// retries — the fixed 30s timeout used for JSON calls would kill legitimate
/// large uploads on slow connections, so uploads instead fail only when bytes
/// stop flowing.
///
/// [fill] is called once per attempt with a fresh request and must add all
/// headers, fields and files (a multipart body can only be sent once).
///
/// Behaviour per attempt:
/// - [stallTimeout]: aborts if no body bytes are accepted by the socket for
///   this long (dead connection), rather than capping total upload time.
/// - [responseTimeout]: once the body is fully sent, how long to wait for the
///   server's reply (covers server-side image/video processing; production
///   gunicorn gives up at 120s, so nothing useful arrives after that).
///
/// Network errors and stalls are retried up to [maxAttempts] with [retryDelays]
/// between attempts, as are 408/429/5xx responses. Other 4xx responses are
/// permanent and returned to the caller immediately.
Future<http.Response> sendMultipart({
  required String method,
  required Uri url,
  required void Function(http.MultipartRequest request) fill,
  void Function(int sentBytes, int totalBytes)? onProgress,
  int maxAttempts = 3,
  Duration stallTimeout = const Duration(seconds: 45),
  Duration responseTimeout = const Duration(seconds: 150),
  List<Duration> retryDelays = const [Duration(seconds: 2), Duration(seconds: 5)],
}) async {
  for (var attempt = 1; ; attempt++) {
    final client = http.Client();
    Timer? watchdog;
    var timedOut = false;
    var waitingOnServer = false;
    void arm(Duration d) {
      watchdog?.cancel();
      watchdog = Timer(d, () {
        timedOut = true;
        client.close(); // Aborts the in-flight request.
      });
    }

    final sw = Stopwatch()..start();
    try {
      final request = _ProgressMultipartRequest(method, url);
      fill(request);
      request.onChunk = (sent, total) {
        onProgress?.call(sent, total);
        // While the body is flowing, each chunk resets the stall watchdog.
        // Once the last byte is handed over, switch to waiting on the server.
        waitingOnServer = sent >= total;
        arm(waitingOnServer ? responseTimeout : stallTimeout);
      };
      arm(stallTimeout); // Covers connect/TLS up to the first body chunk.

      final response = await http.Response.fromStream(await client.send(request));
      watchdog?.cancel();
      ConnectivityStatus().reportSuccess();
      if (kDebugMode) {
        debugPrint('[http] $method ${url.path} -> ${response.statusCode} '
            '(upload attempt $attempt, ${sw.elapsedMilliseconds}ms)');
      }
      if (response.statusCode == 401) {
        onUnauthorized?.call();
      }
      final transientStatus = response.statusCode == 408 ||
          response.statusCode == 429 ||
          response.statusCode >= 500;
      if (!transientStatus || attempt >= maxAttempts) return response;
    } catch (e) {
      watchdog?.cancel();
      final Object error = timedOut
          ? TimeoutException(waitingOnServer
              ? 'Upload timed out waiting for the server to respond'
              : 'Upload stalled — the connection appears to be dead')
          : e;
      if (NoConnectionException.isNetworkError(error)) {
        ConnectivityStatus().reportNetworkFailure();
      }
      if (kDebugMode) {
        debugPrint('[http] $method ${url.path} -> ERROR $error '
            '(upload attempt $attempt, ${sw.elapsedMilliseconds}ms)');
      }
      // Only connection-level failures are worth retrying; anything else
      // (e.g. a bug building the request) would fail identically again.
      final transient = timedOut ||
          e is http.ClientException ||
          NoConnectionException.isNetworkError(e);
      if (!transient || attempt >= maxAttempts) {
        if (error is Exception) throw error;
        rethrow;
      }
    } finally {
      watchdog?.cancel();
      client.close();
    }
    if (retryDelays.isNotEmpty) {
      await Future.delayed(retryDelays[min(attempt - 1, retryDelays.length - 1)]);
    }
  }
}
