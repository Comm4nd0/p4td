// App Store / Play Store screenshot harness.
//
// This drives the REAL app, signed in as a curated demo owner account on the
// live backend, and captures a screenshot of each key owner-facing screen.
//
// It is run via `flutter drive` (see test_driver/integration_test.dart) by the
// tool/screenshots.sh script, which loops over the required device sizes.
//
// Credentials are passed at build time so they never live in the repo:
//   flutter drive ... \
//     --dart-define=DEMO_EMAIL=demo@example.com \
//     --dart-define=DEMO_PASSWORD=•••••
//
// NOTE: the widget finders below assume the current owner UI. If the app
// layout changes, adjust the finders — each capture step is clearly labelled.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:paws4thoughtdogs/main.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/theme_service.dart';
import 'package:paws4thoughtdogs/services/auth_service.dart';
import 'package:firebase_core/firebase_core.dart';

const _demoEmail = String.fromEnvironment('DEMO_EMAIL');
const _demoPassword = String.fromEnvironment('DEMO_PASSWORD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('owner store screenshots', (tester) async {
    expect(
      _demoEmail.isNotEmpty && _demoPassword.isNotEmpty,
      isTrue,
      reason: 'Pass --dart-define=DEMO_EMAIL=.. and --dart-define=DEMO_PASSWORD=..',
    );

    // Mirror the essential parts of main(). We must initialise Firebase
    // because HomeScreen eagerly builds NotificationService, whose constructor
    // touches FirebaseMessaging.instance (which requires a [DEFAULT] app).
    setupLocator();
    await getIt<CacheService>().init();
    await getIt<ThemeService>().init();
    try {
      await Firebase.initializeApp();
    } catch (e) {
      // ignore: avoid_print
      print('Firebase.initializeApp failed (continuing): $e');
    }

    // Sign in as the demo owner (real network call to the production API).
    final loginError = await AuthService().login(_demoEmail, _demoPassword);
    expect(loginError, isNull, reason: 'Demo login failed: $loginError');

    // Boot the real app; MyApp reads the stored token and lands on HomeScreen.
    await tester.pumpWidget(const MyApp());
    await _waitFor(tester, seconds: 4);

    // Required before screenshots on BOTH Android and iOS — render the live
    // Flutter surface into an image. Call once, after the first frames.
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();

    // ── 1. "My Dogs" (home) ────────────────────────────────────────────────
    await binding.takeScreenshot('01_my_dogs');

    // ── 2. Dog profile — open the first dog card ───────────────────────────
    final dogCards = find.byType(InkWell);
    if (dogCards.evaluate().isNotEmpty) {
      await tester.tap(dogCards.first);
      await _waitFor(tester, seconds: 4);
      await binding.takeScreenshot('02_dog_profile');
      await _goBack(tester);
    }

    // ── 3. Feed ────────────────────────────────────────────────────────────
    final feedTab = find.text('Feed');
    if (feedTab.evaluate().isNotEmpty) {
      await tester.tap(feedTab.first);
      await _waitFor(tester, seconds: 4);
      await binding.takeScreenshot('03_feed');
    }

    // ── 4. Profile — open the menu, then the Profile item ──────────────────
    // The owner reaches Profile via the app-bar menu (a ListTile with a user
    // icon). Open whatever menu/drawer the app bar exposes, then tap "Profile".
    final menuButton = find.byType(IconButton);
    if (menuButton.evaluate().isNotEmpty) {
      await tester.tap(menuButton.last);
      await _waitFor(tester, seconds: 2);
      final profileItem = find.text('Profile');
      if (profileItem.evaluate().isNotEmpty) {
        await tester.tap(profileItem.first);
        await _waitFor(tester, seconds: 3);
        await binding.takeScreenshot('04_profile');
      }
    }
  });
}

/// Pumps frames in real time for [seconds], letting real async work (network
/// loads, image decoding) complete without the hangs that `pumpAndSettle` can
/// hit on screens with continuous animations or polling.
Future<void> _waitFor(WidgetTester tester, {required int seconds}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _goBack(WidgetTester tester) async {
  try {
    await tester.pageBack();
  } catch (_) {
    final back = find.byTooltip('Back');
    if (back.evaluate().isNotEmpty) await tester.tap(back.first);
  }
  await _waitFor(tester, seconds: 2);
}
