import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../services/connectivity_status.dart';

/// A slim banner shown at the top of the app whenever recent API calls have
/// failed with a network error. Collapses to zero height when online, so it can
/// be placed above the app's content unconditionally.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityStatus().isOnline,
      builder: (context, online, _) {
        if (online) return const SizedBox.shrink();
        return Material(
          color: Colors.red.shade700,
          child: SafeArea(
            bottom: false,
            child: Semantics(
              liveRegion: true,
              label: 'You are offline. Showing saved data.',
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(PhosphorIconsDuotone.wifiSlash,
                        color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text(
                        'No internet connection — showing saved data',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
