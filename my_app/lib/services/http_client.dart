import 'dart:convert';

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

Future<http.Response> get(Uri url, {Map<String, String>? headers}) =>
    _log('GET', url, () => http.get(url, headers: headers));

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

Future<http.Response> head(Uri url, {Map<String, String>? headers}) =>
    _log('HEAD', url, () => http.head(url, headers: headers));
