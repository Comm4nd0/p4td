import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

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

/// Invoked when the server rejects the auth token (HTTP 401). Wired up in
/// main.dart to sign the user out and route to the login screen, so an
/// invalidated token doesn't leave the app permanently broken (F3). Note: 403
/// is NOT treated as an auth failure here — in this API it means "authenticated
/// but not permitted" (a role check), which must not log the user out.
///
/// [rejectedToken] is the token the failed request was sent with (null for an
/// anonymous request). The handler must compare it with the active token: a
/// phone can hold several accounts, and a late 401 for the account that was
/// just signed out must not sign out the one that took its place.
void Function(String? rejectedToken)? onUnauthorized;

/// The token in a request's `Authorization: Token <key>` header, or null when
/// the request was anonymous (or carried the literal "null" older code sent).
String? tokenFromHeaders(Map<String, String>? headers) {
  if (headers == null) return null;
  String? value;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'authorization') value = entry.value;
  }
  if (value == null || !value.startsWith('Token ')) return null;
  final token = value.substring(6).trim();
  if (token.isEmpty || token == 'null') return null;
  return token;
}

/// Responses worth sending the same upload again for: the server said it did
/// not take the request (timed out reading it, rate limited, or unavailable).
/// A 500, 502 or 504 is deliberately absent — the upload may have been saved
/// before the failure (a proxy giving up on a slow worker is the usual one),
/// and a second copy of a feed post also sends its pushes a second time.
bool isRetryableUploadStatus(int statusCode) =>
    statusCode == 408 || statusCode == 429 || statusCode == 503;

/// Thrown when an upload's whole body reached the server but no answer came
/// back, so nobody knows whether it was saved. Never retried automatically.
class UploadUnconfirmedException implements Exception {
  const UploadUnconfirmedException();

  @override
  String toString() =>
      'The upload was sent but the server did not confirm it. '
      'Check whether it arrived before sending it again.';
}

Future<http.Response> _log(
  String method,
  Uri url,
  Future<http.Response> Function() send, {
  Duration timeout = _defaultTimeout,
  Map<String, String>? headers,
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
      onUnauthorized?.call(tokenFromHeaders(headers));
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
    _log('GET', url, () => http.get(url, headers: headers),
        timeout: timeout, headers: headers);

Future<http.Response> post(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _log('POST', url,
        () => http.post(url, headers: headers, body: body, encoding: encoding),
        headers: headers);

Future<http.Response> put(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _log('PUT', url,
        () => http.put(url, headers: headers, body: body, encoding: encoding),
        headers: headers);

Future<http.Response> patch(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _log('PATCH', url,
        () => http.patch(url, headers: headers, body: body, encoding: encoding),
        headers: headers);

Future<http.Response> delete(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    _log('DELETE', url,
        () => http.delete(url, headers: headers, body: body, encoding: encoding),
        headers: headers);

Future<http.Response> head(Uri url,
        {Map<String, String>? headers, Duration timeout = _defaultTimeout}) =>
    _log('HEAD', url, () => http.head(url, headers: headers),
        timeout: timeout, headers: headers);

/// A file part for [sendMultipart] built from bytes already in memory, handed
/// to the socket in [chunkSize] pieces.
///
/// `MultipartFile.fromBytes` gives the whole file as a single chunk, and
/// [sendMultipart] only knows the upload is alive when a chunk is taken. One
/// chunk means one sign of life: a photo was fine, but a video sent that way
/// showed no progress until it was done and was declared "stalled" whenever
/// it took longer than the stall timeout — on a slow connection, always.
http.MultipartFile chunkedMultipartFile(
  String field,
  List<int> bytes, {
  String? filename,
  MediaType? contentType,
  int chunkSize = 64 * 1024,
}) {
  Stream<List<int>> chunks() async* {
    for (var start = 0; start < bytes.length; start += chunkSize) {
      final end = min(start + chunkSize, bytes.length);
      yield bytes is Uint8List
          ? Uint8List.sublistView(bytes, start, end)
          : bytes.sublist(start, end);
    }
  }

  return http.MultipartFile(
    field,
    http.ByteStream(chunks()),
    bytes.length,
    filename: filename,
    contentType: contentType,
  );
}

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
/// headers, fields and files (a multipart body can only be sent once). It may
/// be async, so a large file can be attached with `MultipartFile.fromPath` and
/// streamed from disk instead of being held in memory.
///
/// Behaviour per attempt:
/// - [stallTimeout]: aborts if no body bytes are accepted by the socket for
///   this long (dead connection), rather than capping total upload time.
/// - [responseTimeout]: once the body is fully sent, how long to wait for the
///   server's reply (covers server-side image/video processing; production
///   gunicorn gives up at 120s, so nothing useful arrives after that).
///
/// **Retried** (up to [maxAttempts], [retryDelays] apart): a connection that
/// fails or stalls while the body is still going up — the server never had the
/// whole request, so nothing was saved — and the responses in
/// [isRetryableUploadStatus].
///
/// **Never retried**: anything after the last byte has been handed over. From
/// there the server may already have stored the upload, and sending it again
/// posts it twice. A silent server or a dropped connection at that point
/// throws [UploadUnconfirmedException]; every other response, 5xx included, is
/// returned to the caller, who can offer the person a retry they chose.
Future<http.Response> sendMultipart({
  required String method,
  required Uri url,
  required FutureOr<void> Function(http.MultipartRequest request) fill,
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
      await fill(request);
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
        onUnauthorized?.call(tokenFromHeaders(request.headers));
      }
      if (!isRetryableUploadStatus(response.statusCode) || attempt >= maxAttempts) {
        return response;
      }
    } catch (e) {
      watchdog?.cancel();
      // The whole body went up and then the line went quiet or dropped: the
      // server may have saved it. Say so rather than send it twice.
      final unconfirmed = waitingOnServer &&
          (timedOut || e is http.ClientException || NoConnectionException.isNetworkError(e));
      final Object error = unconfirmed
          ? const UploadUnconfirmedException()
          : timedOut
              ? TimeoutException('Upload stalled — the connection appears to be dead')
              : e;
      if (timedOut || NoConnectionException.isNetworkError(e)) {
        ConnectivityStatus().reportNetworkFailure();
      }
      if (kDebugMode) {
        debugPrint('[http] $method ${url.path} -> ERROR $error '
            '(upload attempt $attempt, ${sw.elapsedMilliseconds}ms)');
      }
      // Only connection-level failures before the body finished are worth
      // retrying; anything else (e.g. a bug building the request) would fail
      // identically again.
      final transient = !unconfirmed &&
          (timedOut || e is http.ClientException || NoConnectionException.isNetworkError(e));
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
