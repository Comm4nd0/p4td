import 'dart:async';

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

  /// Fired periodically while offline to test whether the server is reachable
  /// again. Wired up in main.dart (like http_client's `onUnauthorized`) to a
  /// lightweight request through the http wrapper, whose outcome feeds back
  /// into [reportSuccess]/[reportNetworkFailure]. A callback rather than a
  /// direct request because http_client imports this file.
  ///
  /// Without the probe, [isOnline] only recovers when the user happens to
  /// trigger a request — with it, signal returning mid-route flips the app
  /// back online (and refreshes stale screens) automatically.
  Future<void> Function()? onProbe;

  static const _probeInterval = Duration(seconds: 30);
  Timer? _probeTimer;

  void reportSuccess() {
    _probeTimer?.cancel();
    _probeTimer = null;
    if (!isOnline.value) isOnline.value = true;
  }

  void reportNetworkFailure() {
    if (isOnline.value) isOnline.value = false;
    _startProbing();
  }

  void _startProbing() {
    final probe = onProbe;
    if (probe == null || _probeTimer != null) return;
    _probeTimer = Timer.periodic(_probeInterval, (_) {
      // The probe's own success/failure loops back into reportSuccess /
      // reportNetworkFailure via the http wrapper; the error is expected
      // while still offline.
      probe().catchError((_) {});
    });
  }
}
