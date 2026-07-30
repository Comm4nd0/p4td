import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_platform_interface/types/auth_messages.dart';

import 'package:paws4thoughtdogs/screens/app_lock_screen.dart';
import 'package:paws4thoughtdogs/services/biometric_service.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';

class _FakeLocalAuth extends LocalAuthentication {
  _FakeLocalAuth({this.result = true});

  bool result;
  int prompts = 0;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const <AuthMessages>[],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    prompts++;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(setupLocator);

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

  /// Mirrors the composition in `main.dart`: the lock is an overlay in
  /// `MaterialApp.builder`, stacked over the app's Navigator rather than
  /// replacing it.
  Widget appUnderTest(BiometricService biometrics) {
    return MaterialApp(
      builder: (context, child) => ListenableBuilder(
        listenable: biometrics,
        builder: (context, _) => Stack(
          children: [
            child ?? const SizedBox.shrink(),
            if (biometrics.isLocked)
              const Positioned.fill(child: AppLockScreen()),
          ],
        ),
      ),
      home: const Scaffold(body: Center(child: Text('SENSITIVE DOG DATA'))),
    );
  }

  testWidgets('a locked app covers the content behind it', (tester) async {
    final fake = _FakeLocalAuth(result: true);
    final biometrics = BiometricService()..auth = fake;
    await biometrics.init();
    await biometrics.setEnabled(true);
    await biometrics.init(); // relaunch → locked

    // From here the prompt fails, so the lock screen stays put to be inspected.
    fake.result = false;
    expect(biometrics.isLocked, isTrue);

    await tester.pumpWidget(appUnderTest(biometrics));
    await tester.pumpAndSettle();

    expect(find.text('App Locked'), findsOneWidget);
    // The route underneath is still mounted (state is preserved) but the lock
    // is painted over it.
    expect(find.text('SENSITIVE DOG DATA'), findsOneWidget);
    expect(
      tester.getRect(find.byType(AppLockScreen)),
      tester.getRect(find.byType(MaterialApp)),
      reason: 'the lock must cover the whole window, not sit in a corner',
    );
  });

  testWidgets('a failed prompt offers Try Again and does not let the user through',
      (tester) async {
    final fake = _FakeLocalAuth(result: true);
    final biometrics = BiometricService()..auth = fake;
    await biometrics.init();
    await biometrics.setEnabled(true);
    await biometrics.init(); // relaunch → locked

    fake.result = false;
    await tester.pumpWidget(appUnderTest(biometrics));
    await tester.pumpAndSettle();

    expect(find.text('Try Again'), findsOneWidget);
    expect(biometrics.isLocked, isTrue);

    final before = fake.prompts;
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(fake.prompts, before + 1, reason: 'Try Again re-prompts');
    expect(biometrics.isLocked, isTrue);
  });

  testWidgets('a successful prompt removes the lock', (tester) async {
    final fake = _FakeLocalAuth(result: true);
    final biometrics = BiometricService()..auth = fake;
    await biometrics.init();
    await biometrics.setEnabled(true);
    await biometrics.init(); // relaunch → locked

    await tester.pumpWidget(appUnderTest(biometrics));
    await tester.pumpAndSettle();

    expect(biometrics.isLocked, isFalse);
    expect(find.text('App Locked'), findsNothing);
    expect(find.text('SENSITIVE DOG DATA'), findsOneWidget);
  });

  testWidgets('sign out takes two taps', (tester) async {
    final fake = _FakeLocalAuth(result: true);
    final biometrics = BiometricService()..auth = fake;
    await biometrics.init();
    await biometrics.setEnabled(true);
    await biometrics.init(); // relaunch → locked

    fake.result = false; // stay on the lock screen
    await tester.pumpWidget(appUnderTest(biometrics));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign out instead'));
    await tester.pump();

    expect(find.text('Tap again to sign out'), findsOneWidget);
    expect(biometrics.isEnabled, isTrue, reason: 'one tap must not sign out');
  });
}
