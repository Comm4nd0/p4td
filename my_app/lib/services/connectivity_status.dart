import 'package:flutter/foundation.dart';

/// Tracks whether recent API calls are reaching the server.
///
/// This is inferred from real request outcomes (see `http_client.dart`) rather
/// than a platform connectivity plugin: a successful response marks the app
/// online, a network-level failure marks it offline. UI can listen via
/// [isOnline] to show an offline banner.
class ConnectivityStatus {
  static final ConnectivityStatus _instance = ConnectivityStatus._internal();
  factory ConnectivityStatus() => _instance;
  ConnectivityStatus._internal();

  /// `true` until a request fails with a network error. Notifies listeners on
  /// every change.
  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);

  void reportSuccess() {
    if (!isOnline.value) isOnline.value = true;
  }

  void reportNetworkFailure() {
    if (isOnline.value) isOnline.value = false;
  }
}
