import 'package:flutter/material.dart';

/// An opaque branded panel shown over the app's content as it leaves the
/// foreground, so the OS task-switcher snapshot doesn't capture the screen the
/// user was on.
///
/// Unlike the lock screen this needs no authentication to dismiss — it clears
/// on its own when the app comes back. It only appears when the app lock is
/// switched on; without the lock there's nothing the user asked us to hide.
class PrivacyCover extends StatelessWidget {
  const PrivacyCover({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Center(
        child: Image.asset('assets/logo.png', height: 96),
      ),
    );
  }
}
