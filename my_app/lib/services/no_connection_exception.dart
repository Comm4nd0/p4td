import 'dart:async';
import 'dart:io';

/// Exception thrown when a network request fails due to no internet connection.
class NoConnectionException implements Exception {
  final String message;

  const NoConnectionException([this.message = 'No internet connection']);

  @override
  String toString() => message;

  /// Returns true if the given error is a network connectivity issue.
  static bool isNetworkError(Object error) {
    if (error is SocketException) return true;
    if (error is TimeoutException) return true;
    // HandshakeException can occur when connection drops mid-TLS
    if (error is HandshakeException) return true;
    final msg = error.toString().toLowerCase();
    return msg.contains('socketexception') ||
        msg.contains('connection refused') ||
        msg.contains('network is unreachable') ||
        msg.contains('no address associated') ||
        msg.contains('connection reset') ||
        msg.contains('host lookup');
  }
}
