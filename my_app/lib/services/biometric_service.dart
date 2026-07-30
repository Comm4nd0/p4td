import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Re-exported so screens can label the setting without importing the plugin.
export 'package:local_auth/local_auth.dart' show BiometricType;

/// Guards an already-signed-in session behind the device's biometrics.
///
/// The app keeps a long-lived auth token in secure storage and skips the login
/// screen on relaunch, so without this anyone holding the unlocked phone has
/// the full session — including staff screens and customer data. When the lock
/// is enabled the app shows [AppLockScreen] before the dashboard on launch, and
/// again after it has been in the background longer than [_gracePeriod].
///
/// Authentication deliberately allows the device passcode as a fallback
/// (`biometricOnly: false`): removing an enrolled fingerprint must not strand
/// the user in a lock screen they can never pass.
class BiometricService extends ChangeNotifier {
  static final BiometricService _instance = BiometricService._internal();
  factory BiometricService() => _instance;
  BiometricService._internal();

  /// Overridable for tests — the plugin needs a real device otherwise.
  @visibleForTesting
  LocalAuthentication auth = LocalAuthentication();

  /// Overridable for tests, so the grace period can be exercised without
  /// actually waiting a minute.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  final _storage = const FlutterSecureStorage();

  static const _kEnabled = 'app_lock_enabled';

  /// How long the app may sit in the background before it re-locks. Short
  /// enough to matter if the phone changes hands, long enough that switching
  /// out to the camera or a maps app doesn't demand a fingerprint on return.
  static const _gracePeriod = Duration(seconds: 60);

  bool _enabled = false;

  /// Whether the user has opted in to the app lock on this device.
  bool get isEnabled => _enabled;

  bool _isLocked = false;

  /// Whether the session is currently hidden behind the lock screen.
  bool get isLocked => _isLocked;

  DateTime? _backgroundedAt;

  bool _obscured = false;

  /// Whether the app's content should be hidden behind a privacy cover right
  /// now — i.e. the app is leaving the foreground.
  ///
  /// This is separate from [isLocked] and needs no authentication to clear. It
  /// exists because the OS snapshots the app for the task switcher *as it
  /// backgrounds*, well before [lockIfExpired] runs on the way back in. Without
  /// a cover, that snapshot shows whatever screen the user was on.
  bool get isObscured => _obscured;

  bool _authInFlight = false;

  /// Loads the persisted preference. Call once at startup, before `runApp`.
  ///
  /// If the lock is on, the app starts locked — the very first thing a launch
  /// should ask for is the fingerprint, not after a frame of dashboard.
  Future<void> init() async {
    _enabled = await _storage.read(key: _kEnabled) == 'true';
    _isLocked = _enabled;
    _obscured = false; // A fresh launch has nothing to hide yet.
    _backgroundedAt = null;
    notifyListeners();
  }

  /// Whether this device can actually perform the check — hardware present and
  /// something enrolled (biometric, PIN, pattern or passcode). False on a phone
  /// with no screen lock at all, where there is nothing to authenticate against.
  Future<bool> isAvailable() async {
    try {
      return await auth.isDeviceSupported();
    } on PlatformException catch (e) {
      _log('isAvailable', e);
      return false;
    }
  }

  /// The enrolled biometric kinds, used only to label the setting ("Face ID"
  /// vs "Fingerprint"). An empty list still permits a passcode unlock.
  Future<List<BiometricType>> availableBiometrics() async {
    try {
      return await auth.getAvailableBiometrics();
    } on PlatformException catch (e) {
      _log('availableBiometrics', e);
      return const <BiometricType>[];
    }
  }

  /// Prompts for biometrics (or the device passcode). Returns true only on a
  /// confirmed success — any error is treated as a failure to unlock.
  Future<bool> authenticate({
    String reason = 'Unlock Paws 4 Thought Dogs',
  }) async {
    // The system prompt drives the app `inactive`. Without this the privacy
    // cover would slam over the lock screen every time it asked to be unlocked.
    _authInFlight = true;
    try {
      return await auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          // Allow the device passcode so a user who removes their fingerprints
          // still has a way in.
          biometricOnly: false,
          // Keep the prompt up across a brief app switch rather than failing.
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException catch (e) {
      _log('authenticate', e);
      return false;
    } finally {
      _authInFlight = false;
    }
  }

  /// Turns the lock on or off. Enabling requires a successful authentication
  /// first, so a passer-by can't switch it on and lock the real owner out, and
  /// disabling requires one too, so they can't switch it off unattended.
  ///
  /// Returns true if the preference changed.
  Future<bool> setEnabled(bool value) async {
    if (_enabled == value) return true;

    final ok = await authenticate(
      reason: value
          ? 'Confirm it\'s you to turn on App Lock'
          : 'Confirm it\'s you to turn off App Lock',
    );
    if (!ok) return false;

    _enabled = value;
    // Turning the lock on mid-session shouldn't immediately hide the screen the
    // user is standing on — they just proved who they are.
    _isLocked = false;
    _backgroundedAt = null;
    if (value) {
      await _storage.write(key: _kEnabled, value: 'true');
    } else {
      await _storage.delete(key: _kEnabled);
    }
    notifyListeners();
    return true;
  }

  /// Clears the lock after a successful unlock.
  void unlock() {
    if (!_isLocked) return;
    _isLocked = false;
    _obscured = false;
    _backgroundedAt = null;
    notifyListeners();
  }

  /// Called when the app is backgrounded, to start the grace-period clock.
  ///
  /// Only genuine `paused` transitions should reach here. On iOS the biometric
  /// prompt itself makes the app `inactive`, so treating that as backgrounding
  /// would re-lock the app every time it asked to be unlocked.
  void noteBackgrounded() {
    if (!_enabled || _isLocked) return;
    _backgroundedAt = now();
  }

  /// Called as the app leaves the foreground — including `inactive`, which is
  /// the earliest warning available and fires before the task-switcher snapshot
  /// on both platforms.
  void obscure() {
    // Nothing to hide if the lock is off, if the lock screen is already up, or
    // if it's our own auth prompt that pushed the app inactive.
    if (!_enabled || _isLocked || _authInFlight || _obscured) return;
    _obscured = true;
    notifyListeners();
  }

  /// Called when the app returns to the foreground. Re-locks if it was away for
  /// longer than the grace period, and drops the privacy cover either way —
  /// when it re-locks, the lock screen takes over the covering.
  void lockIfExpired() {
    final wasObscured = _obscured;
    _obscured = false;

    if (!_enabled || _isLocked) {
      if (wasObscured) notifyListeners();
      return;
    }
    final since = _backgroundedAt;
    if (since == null || now().difference(since) < _gracePeriod) {
      if (wasObscured) notifyListeners();
      return;
    }
    _isLocked = true;
    _backgroundedAt = null;
    notifyListeners();
  }

  /// Drops the lock state on sign-out — the login screen must never sit behind
  /// a lock screen. The stored preference survives for the next sign-in.
  void resetForSignOut() {
    _isLocked = false;
    _obscured = false;
    _backgroundedAt = null;
    notifyListeners();
  }

  void _log(String context, Object error) {
    if (kDebugMode) {
      debugPrint('BiometricService.$context: $error');
    }
  }
}
