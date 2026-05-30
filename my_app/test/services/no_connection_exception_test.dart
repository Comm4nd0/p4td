import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paws4thoughtdogs/services/no_connection_exception.dart';

void main() {
  group('NoConnectionException.isNetworkError', () {
    test('detects typed network errors', () {
      expect(NoConnectionException.isNetworkError(const SocketException('boom')), isTrue);
      expect(NoConnectionException.isNetworkError(TimeoutException('slow')), isTrue);
      expect(NoConnectionException.isNetworkError(const HandshakeException('tls')), isTrue);
    });

    test('detects network errors from message text', () {
      expect(NoConnectionException.isNetworkError('Connection refused'), isTrue);
      expect(NoConnectionException.isNetworkError('Network is unreachable'), isTrue);
      expect(NoConnectionException.isNetworkError('Failed host lookup'), isTrue);
      expect(NoConnectionException.isNetworkError('Connection reset by peer'), isTrue);
    });

    test('does not flag unrelated errors', () {
      expect(NoConnectionException.isNetworkError(const FormatException('bad json')), isFalse);
      expect(NoConnectionException.isNetworkError('Validation failed'), isFalse);
    });

    test('toString returns the message', () {
      expect(const NoConnectionException().toString(), 'No internet connection');
      expect(const NoConnectionException('Offline').toString(), 'Offline');
    });
  });
}
