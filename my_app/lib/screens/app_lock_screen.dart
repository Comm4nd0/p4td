import 'package:flutter/material.dart';
import 'package:picons/picons.dart';

import '../main.dart' show navigatorKey;
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/service_locator.dart';
import 'landing_screen.dart';

/// Covers the app's content while the session is locked.
///
/// Prompts for biometrics as soon as it appears. If the user cancels or fails,
/// it stays put with a Try Again button — there is no way past it except a
/// successful unlock or signing out.
///
/// This is rendered by `MaterialApp.builder` so that it covers every route, not
/// just the launch one. That places it *above* the app's [Navigator], so it
/// must not rely on `Navigator.of(context)` — sign-out routes through the root
/// [navigatorKey], and the confirmation is an inline two-tap rather than a
/// dialog.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _biometrics = getIt<BiometricService>();

  bool _authenticating = false;
  bool _failed = false;
  bool _confirmingSignOut = false;

  @override
  void initState() {
    super.initState();
    // Prompt on arrival rather than making the user tap first.
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _failed = false;
    });

    final ok = await _biometrics.authenticate();

    if (!mounted) return;
    if (ok) {
      // The root gate listens to the service and swaps in the real UI.
      _biometrics.unlock();
      return;
    }
    setState(() {
      _authenticating = false;
      _failed = true;
    });
  }

  Future<void> _signOut() async {
    // First tap arms the action, second confirms — a dialog isn't available
    // from above the Navigator, and this keeps an accidental tap from wiping
    // the device's saved sessions.
    if (!_confirmingSignOut) {
      setState(() => _confirmingSignOut = true);
      return;
    }

    await getIt<AuthService>().logoutAll();
    _biometrics.resetForSignOut();
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LandingScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset('assets/logo.png', height: 96),
                const SizedBox(height: 40),
                Picon(
                  PiconsDuotone.fingerprint,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  'App Locked',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  _failed
                      ? 'Couldn\'t verify it\'s you. Try again to continue.'
                      : 'Unlock to get back to your dogs.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _authenticating ? null : _unlock,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _authenticating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_failed ? 'Try Again' : 'Unlock'),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _authenticating ? null : _signOut,
                  style: _confirmingSignOut
                      ? TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error)
                      : null,
                  child: Text(
                    _confirmingSignOut
                        ? 'Tap again to sign out'
                        : 'Sign out instead',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
