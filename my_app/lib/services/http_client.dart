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

Future<http.Response> _log(
  String method,
  Uri url,
  Future<http.Response> Function() send,
) async {
  final sw = Stopwatch()..start();
  try {
    final response = await send();
    sw.stop();
    // A response (even a 4xx/5xx) means the server is reachable.
    ConnectivityStatus().reportSuccess();
    if (kDebugMode) {
      debugPrint('[http] $method ${url.path} -> ${response.statusCode} '
          '(${sw.elapsedMilliseconds}ms)');
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
