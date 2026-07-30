import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
// AuthMessages isn't re-exported by local_auth, but the method being overridden
// names it, so the override has to reach for it directly.
import 'package:local_auth_platform_interface/types/auth_messages.dart';
import 'package:paws4thoughtdogs/services/biometric_service.dart';

/// Stands in for the platform plugin, which needs a real device with real
/// enrolled biometrics. [result] is what the next prompt "returns"; [calls]
/// records the reasons it was shown, so tests can assert the user was actually
/// challenged rather than silently let through.
class _FakeLocalAuth extends LocalAuthentication {
  _FakeLocalAuth({this.result = true, this.throwOnAuth = false});

  bool result;
  bool throwOnAuth;
  final List<String> calls = <String>[];

  /// Runs while the prompt is notionally on screen, so tests can observe the
  /// service's state mid-authentication.
  void Function()? onAuthenticate;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const <AuthMessages>[],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    calls.add(localizedReason);
    onAuthenticate?.call();
    if (throwOnAuth) {
      throw PlatformException(code: 'NotAvailable');
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // In-memory stand-in for the secure-storage platform channel.
  final store = <String, String>{};

  setUp(() {
    store.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        switch (call.method) {
          case 'write':
            store[args['key'] as String] = args['value'] as String;
            return null;
          case 'read':
            return store[args['key'] as String];
          case 'delete':
            store.remove(args['key'] as String);
            return null;
          case 'readAll':
            return store;
          case 'deleteAll':
            store.clear();
            return null;
        }
        return null;
      },
    );
  });

  /// The service is a singleton, so each test resets it to a known state.
  Future<BiometricService> freshService(_FakeLocalAuth fake) async {
    final service = BiometricService()
      ..auth = fake
      ..now = DateTime.now;
    await service.init();
    return service;
  }

  group('enable / disable', () {
    test('starts disabled and unlocked', () async {
      final service = await freshService(_FakeLocalAuth());
      expect(service.isEnabled, isFalse);
      expect(service.isLocked, isFalse);
    });

    test('enabling requires a successful authentication', () async {
      final fake = _FakeLocalAuth(result: false);
      final service = await freshService(fake);

      final ok = await service.setEnabled(true);

      expect(ok, isFalse);
      expect(service.isEnabled, isFalse, reason: 'a failed prompt must not arm the lock');
      expect(fake.calls, hasLength(1));
    });

    test('enabling persists across a restart, and comes back locked', () async {
      final service = await freshService(_FakeLocalAuth());
      expect(await service.setEnabled(true), isTrue);
      expect(service.isEnabled, isTrue);
      // Turning it on mid-session must not hide the screen the user is on.
      expect(service.isLocked, isFalse);

      // Simulate a relaunch: same persisted store, fresh init.
      await service.init();
      expect(service.isEnabled, isTrue);
      expect(service.isLocked, isTrue, reason: 'a launch must ask before showing the app');
    });

    test('disabling also requires authentication', () async {
      final fake = _FakeLocalAuth();
      final service = await freshService(fake);
      await service.setEnabled(true);

      fake.result = false;
      expect(await service.setEnabled(false), isFalse);
      expect(service.isEnabled, isTrue, reason: 'a passer-by must not be able to switch it off');

      fake.result = true;
      expect(await service.setEnabled(false), isTrue);
      expect(service.isEnabled, isFalse);
    });

    test('a platform error is treated as a failed unlock, not a pass', () async {
      final service = await freshService(_FakeLocalAuth(throwOnAuth: true));
      expect(await service.authenticate(), isFalse);
      expect(await service.setEnabled(true), isFalse);
      expect(service.isEnabled, isFalse);
    });
  });

  group('backgrounding', () {
    test('re-locks after the grace period', () async {
      final service = await freshService(_FakeLocalAuth());
      await service.setEnabled(true);

      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      service.now = () => clock;

      service.noteBackgrounded();
      clock = clock.add(const Duration(seconds: 61));
      service.lockIfExpired();

      expect(service.isLocked, isTrue);
    });

    test('a brief trip to the camera does not re-lock', () async {
      final service = await freshService(_FakeLocalAuth());
      await service.setEnabled(true);

      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      service.now = () => clock;

      service.noteBackgrounded();
      clock = clock.add(const Duration(seconds: 5));
      service.lockIfExpired();

      expect(service.isLocked, isFalse);
    });

    test('does nothing while the lock is switched off', () async {
      final service = await freshService(_FakeLocalAuth());

      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      service.now = () => clock;

      service.noteBackgrounded();
      clock = clock.add(const Duration(hours: 3));
      service.lockIfExpired();

      expect(service.isLocked, isFalse);
    });

    test('resuming without a prior background does not lock', () async {
      final service = await freshService(_FakeLocalAuth());
      await service.setEnabled(true);
      service.lockIfExpired();
      expect(service.isLocked, isFalse);
    });
  });

  group('privacy cover', () {
    test('goes up when the app leaves the foreground', () async {
      final service = await freshService(_FakeLocalAuth());
      await service.setEnabled(true);

      expect(service.isObscured, isFalse);
      service.obscure();
      expect(service.isObscured, isTrue);
    });

    test('stays down when the lock is switched off', () async {
      final service = await freshService(_FakeLocalAuth());
      service.obscure();
      expect(service.isObscured, isFalse,
          reason: 'nothing to hide if the user never asked for a lock');
    });

    test('does not appear over our own auth prompt', () async {
      // The prompt drives the app inactive; obscuring then would slam a cover
      // over the lock screen every time it asked to be unlocked.
      final fake = _FakeLocalAuth();
      final service = await freshService(fake);
      await service.setEnabled(true);

      late bool obscuredDuringPrompt;
      fake.onAuthenticate = () {
        service.obscure();
        obscuredDuringPrompt = service.isObscured;
      };
      await service.authenticate();

      expect(obscuredDuringPrompt, isFalse);
      expect(service.isObscured, isFalse);
    });

    test('clears on resume when the grace period has not expired', () async {
      final service = await freshService(_FakeLocalAuth());
      await service.setEnabled(true);

      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      service.now = () => clock;

      service.obscure();
      service.noteBackgrounded();
      clock = clock.add(const Duration(seconds: 5));
      service.lockIfExpired();

      expect(service.isObscured, isFalse);
      expect(service.isLocked, isFalse);
    });

    test('hands over to the lock screen when the grace period has expired',
        () async {
      final service = await freshService(_FakeLocalAuth());
      await service.setEnabled(true);

      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      service.now = () => clock;

      service.obscure();
      service.noteBackgrounded();
      clock = clock.add(const Duration(minutes: 10));
      service.lockIfExpired();

      expect(service.isLocked, isTrue);
      expect(service.isObscured, isFalse,
          reason: 'the lock screen does the covering from here');
    });
  });

  group('unlock and sign-out', () {
    test('unlock clears the lock and notifies listeners', () async {
      final service = await freshService(_FakeLocalAuth());
      await service.setEnabled(true);
      await service.init(); // relaunch → locked

      var notified = 0;
      void listener() => notified++;
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      service.unlock();

      expect(service.isLocked, isFalse);
      expect(notified, 1);
    });

    test('signing out drops the lock but keeps the preference', () async {
      final service = await freshService(_FakeLocalAuth());
      await service.setEnabled(true);
      await service.init(); // relaunch → locked

      service.resetForSignOut();

      expect(service.isLocked, isFalse,
          reason: 'the login screen must not sit behind a lock screen');
      expect(service.isEnabled, isTrue,
          reason: 'the device preference should survive for the next sign-in');
    });
  });
}
