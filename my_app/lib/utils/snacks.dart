import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/no_connection_exception.dart';

/// Snackbar helpers shared by every screen.
///
/// These replace six near-identical private `_showError` / `_showSuccess`
/// copies, four of which were missing the `mounted` check — which is exactly
/// the bug ("setState/ScaffoldMessenger after dispose") that kept recurring
/// whenever the pattern was copied into a new screen. Centralising the guard
/// means a new screen gets it for free.
extension SnackMessages on State {
  /// Red error snackbar. Safe to call after an await — no-ops if disposed.
  void showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(userMessage(error)), backgroundColor: AppColors.error),
    );
  }

  /// Green confirmation snackbar. Safe to call after an await.
  void showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.success),
    );
  }

  /// Plain snackbar with no colour, for neutral information.
  void showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Turn anything throwable into something worth showing a dog owner.
///
/// Screens used to interpolate `$e` straight into a snackbar, so customers saw
/// `ClientException with SocketException: Failed host lookup: 'paws...'` or a
/// raw DRF error body. Known messages are passed through (the API's `detail`
/// strings are written for users); everything else is replaced.
String userMessage(Object? error) {
  if (error == null) return 'Something went wrong. Please try again.';
  if (error is String) return error;

  if (NoConnectionException.isNetworkError(error)) {
    return "You're offline. Check your connection and try again.";
  }

  var text = error.toString();
  // `Exception: Failed to load dogs` -> `Failed to load dogs`
  if (text.startsWith('Exception: ')) {
    text = text.substring('Exception: '.length);
  }

  // Anything still carrying framework or transport noise is not for a customer.
  const noise = [
    'SocketException',
    'ClientException',
    'HandshakeException',
    'TimeoutException',
    'FormatException',
    'HttpException',
    'type \'',        // "type 'Null' is not a subtype of..."
    'Instance of',
    '<!DOCTYPE',      // an HTML error page from a proxy
    '{"',             // a raw JSON body
  ];
  for (final marker in noise) {
    if (text.contains(marker)) {
      return 'Something went wrong. Please try again.';
    }
  }

  if (text.trim().isEmpty || text.length > 160) {
    return 'Something went wrong. Please try again.';
  }
  return text;
}
