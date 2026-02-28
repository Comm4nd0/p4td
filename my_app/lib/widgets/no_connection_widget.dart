import 'package:flutter/material.dart';
import '../constants/app_colors.dart';

/// A friendly full-screen widget shown when the device has no internet connection.
///
/// Displays the app logo, a wifi-off icon, and a message asking the user
/// to check their connection. An optional [onRetry] callback shows a retry button.
class NoConnectionWidget extends StatelessWidget {
  final VoidCallback? onRetry;

  const NoConnectionWidget({super.key, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/logo.png', height: 100),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.grey100,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.wifi_off_rounded,
                size: 64,
                color: AppColors.grey500,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'No Internet Connection',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryDark,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'An internet connection is required to use this app. '
              'Please check your Wi-Fi or mobile data and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: AppColors.grey600,
                height: 1.4,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 14,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
