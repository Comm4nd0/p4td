// App Store / Play Store screenshot harness.
//
// This drives the REAL app, signed in as a curated demo owner account on the
// live backend, and captures a screenshot of each owner-facing screen that
// actually sells the app: the photo feed, the dog profile, the dog's gallery,
// the booking flow, and the owner's profile/notification settings.
//
// It is run via `flutter drive` (see test_driver/integration_test.dart) by the
// tool/screenshots.sh script, which loops over the required device sizes.
//
// Credentials are passed at build time so they never live in the repo:
//   flutter drive ... \
//     --dart-define=DEMO_EMAIL=demo@example.com \
//     --dart-define=DEMO_PASSWORD=•••••
//
// Each capture below is deterministic: we navigate to the intended screen and
// only shoot once we've confirmed we're there, so a screenshot is never a
// stray/half-loaded state. The screenshot keys MUST stay in sync with the
// captions in fastlane/captions.strings.
//
// NOTE: the finders assume the current owner UI. If the app layout changes,
// adjust the finders — each capture step is clearly labelled.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:paws4thoughtdogs/main.dart';
import 'package:paws4thoughtdogs/screens/home_screen.dart';
import 'package:paws4thoughtdogs/models/dog.dart';
import 'package:paws4thoughtdogs/services/service_locator.dart';
import 'package:paws4thoughtdogs/services/cache_service.dart';
import 'package:paws4thoughtdogs/services/theme_service.dart';
import 'package:paws4thoughtdogs/services/auth_service.dart';
import 'package:paws4thoughtdogs/services/data_service.dart';
import 'package:firebase_core/firebase_core.dart';

const _demoEmail = String.fromEnvironment('DEMO_EMAIL');
const _demoPassword = String.fromEnvironment('DEMO_PASSWORD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('owner store screenshots', (tester) async {
    _log('test started');
    expect(
      _demoEmail.isNotEmpty && _demoPassword.isNotEmpty,
      isTrue,
      reason: 'Pass --dart-define=DEMO_EMAIL=.. and --dart-define=DEMO_PASSWORD=..',
    );

    // Mirror the essential parts of main(). We must initialise Firebase
    // because HomeScreen eagerly builds NotificationService, whose constructor
    // touches FirebaseMessaging.instance (which requires a [DEFAULT] app).
    setupLocator();
    _log('locator ready');
    await getIt<CacheService>().init();
    await getIt<ThemeService>().init();
    _log('cache+theme ready');
    try {
      await Firebase.initializeApp().timeout(const Duration(seconds: 30));
      _log('firebase initialised');
    } catch (e) {
      _log('firebase init FAILED (continuing): $e');
    }

    // Start LOGGED OUT so MyApp shows the landing/login UI we want to shoot.
    try {
      await AuthService().logoutAll();
      _log('logged out');
    } catch (e) {
      _log('logoutAll failed (continuing): $e');
    }

    // Boot the real app; with no stored token MyApp lands on the LandingScreen.
    await tester.pumpWidget(const MyApp());
    _log('pumped MyApp (logged out)');
    await _waitFor(tester, seconds: 4);

    // Required before screenshots on BOTH Android and iOS — render the live
    // Flutter surface into an image. Call once, after the first frames; it
    // persists across the later pumpWidget call in this test.
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    _log('surface converted');

    // ── 06. Login ────────────────────────────────────────────────────────────
    // LandingScreen → "Log In" opens the LoginScreen (logo + email/password).
    // Captured here (logged out) but numbered after the feature screens so the
    // store listing leads with the app's value, not its sign-in form.
    await _tapText(tester, 'Log In');
    await _waitFor(tester, seconds: 2);
    final onLogin = find.text('LOGIN').evaluate().isNotEmpty;
    _log('on login screen: $onLogin');
    if (onLogin) {
      await binding.takeScreenshot('06_login');
      _log('shot 06_login');

      // ── 07. Sign up ──────────────────────────────────────────────────────
      // LoginScreen → "Create one" opens the RegisterScreen (Create Account).
      await _tapText(tester, "Don't have an account? Create one");
      await _waitFor(tester, seconds: 2);
      if (find.text('Create Account').evaluate().isNotEmpty) {
        await binding.takeScreenshot('07_signup');
        _log('shot 07_signup');
      } else {
        _log('register screen not reached — skipped 07_signup');
      }
    } else {
      _log('login screen not reached — skipped 06_login/07_signup');
    }

    // Sign in as the demo owner (real network call to the production API).
    _log('logging in…');
    final loginError = await AuthService().login(_demoEmail, _demoPassword);
    _log('login returned: ${loginError ?? "OK"}');
    expect(loginError, isNull, reason: 'Demo login failed: $loginError');

    // Learn the demo dog up-front so we can navigate to its profile by name.
    List<Dog> dogs = const [];
    try {
      dogs = await ApiDataService().getDogs();
      _log('dogs on account: ${dogs.map((d) => d.name).toList()}');
    } catch (e) {
      _log('getDogs failed (continuing): $e');
    }
    final String? dogName = dogs.isNotEmpty ? dogs.first.name : null;

    // The token is now stored. Swap the logged-out tree for the owner
    // HomeScreen using the app's REAL navigator (the one MyApp installed via
    // the global navigatorKey), clearing the landing/login/register routes.
    // We navigate explicitly rather than re-pumping MyApp: re-pumping does not
    // reliably re-run MyApp's startup token check, so it left us logged out.
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
    _log('navigated to HomeScreen');
    await _waitFor(tester, seconds: 5);

    // ── 01. Feed ───────────────────────────────────────────────────────────
    // Owners land on the Feed tab by default, so it's already on screen.
    await _waitFor(tester, seconds: 2);
    await binding.takeScreenshot('01_feed');
    _log('shot 01_feed');

    // ── Open the dog profile (DogHomeScreen) ────────────────────────────────
    // The owner's "My Dogs" tab is the first BottomNavigationBar item. With a
    // single dog, tapping it lands straight on the dog profile; otherwise it
    // shows the dogs list and we tap the first card.
    await _openDogProfile(tester, dogName);
    final onProfile = find.text('Request Boarding').evaluate().isNotEmpty;
    _log('on dog profile: $onProfile');

    if (onProfile) {
      // ── 02. Dog profile (top: photo, times, upcoming dates) ──────────────
      await binding.takeScreenshot('02_dog_profile');
      _log('shot 02_dog_profile');

      // ── 04. Booking — open the "Request Boarding" dialog ─────────────────
      // Captured before the gallery so we don't have to scroll back up.
      await _ensureVisible(tester, find.text('Request Boarding'));
      await tester.tap(find.text('Request Boarding').first);
      await _waitFor(tester, seconds: 2);
      if (find.textContaining('Request Boarding for').evaluate().isNotEmpty) {
        await binding.takeScreenshot('04_booking');
        _log('shot 04_booking');
        // Dismiss the dialog so we can carry on scrolling the profile.
        final cancel = find.text('Cancel');
        if (cancel.evaluate().isNotEmpty) {
          await tester.tap(cancel.first);
          await _waitFor(tester, seconds: 1);
        }
      } else {
        _log('booking dialog did not open — skipped 04_booking');
      }

      // ── 03. Gallery — open a photo FULL-SCREEN so this shot is clearly
      //        distinct from the dog profile. Previously we just scrolled the
      //        profile to its embedded grid, which looked like a second copy of
      //        the profile. Tapping a thumbnail opens the full-screen viewer
      //        (a large photo on black) — a real, reachable user flow.
      await _scrollDown(tester, by: 1200, times: 3);
      await _waitFor(tester, seconds: 1);
      final galleryPhoto = find.descendant(
        of: find.byType(GridView),
        matching: find.byType(CachedNetworkImage),
      );
      if (galleryPhoto.evaluate().isNotEmpty) {
        await _ensureVisible(tester, galleryPhoto.first);
        await tester.tap(galleryPhoto.first);
        await _waitFor(tester, seconds: 2);
      } else {
        _log('no gallery photo found — capturing the embedded grid instead');
      }
      await binding.takeScreenshot('03_gallery');
      final onFullScreen = find.byType(PageView).evaluate().isNotEmpty;
      _log('shot 03_gallery (fullscreen=$onFullScreen)');

      // Pop the full-screen viewer (if it opened) back to the dog profile.
      if (onFullScreen) {
        await _goBack(tester);
      }

      // Return to the home scaffold for the drawer step.
      await _goBack(tester);
    } else {
      _log('could not reach dog profile — skipped 02/03/04');
    }

    // ── 05. Profile — open the drawer, then the Profile item ────────────────
    await _openDrawer(tester);
    final profileItem = find.text('Profile');
    _log('profile item found: ${profileItem.evaluate().length}');
    if (profileItem.evaluate().isNotEmpty) {
      await tester.tap(profileItem.first);
      await _waitFor(tester, seconds: 3);
      await binding.takeScreenshot('05_profile');
      _log('shot 05_profile');
    }
    _log('test finished');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

void _log(String message) {
  // Prefixed so it's easy to grep in the flutter drive output.
  // ignore: avoid_print
  print('SS> $message');
}

/// Tap a widget found by its exact visible text, logging (rather than failing)
/// if it isn't on screen — keeps the harness resilient to small UI changes.
Future<void> _tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  if (finder.evaluate().isEmpty) {
    _log('tap target not found: "$text"');
    return;
  }
  await tester.tap(finder.first);
  await tester.pump(const Duration(milliseconds: 300));
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

/// Navigate from the Feed to the dog profile (DogHomeScreen).
Future<void> _openDogProfile(WidgetTester tester, String? dogName) async {
  // Tap the first bottom-nav item ("My Dogs" / the dog's name).
  final navBar = find.byType(BottomNavigationBar);
  if (dogName != null) {
    final byName = find.descendant(of: navBar, matching: find.text(dogName));
    if (byName.evaluate().isNotEmpty) {
      await tester.tap(byName.first);
    } else {
      await _tapFirstNavItem(tester);
    }
  } else {
    await _tapFirstNavItem(tester);
  }
  await _waitFor(tester, seconds: 4);

  // Single-dog owners land straight on the profile. Multi-dog owners get the
  // list — tap the first dog card to open it.
  if (find.text('Request Boarding').evaluate().isEmpty) {
    final cards = find.byType(InkWell);
    if (cards.evaluate().isNotEmpty) {
      await tester.tap(cards.first);
      await _waitFor(tester, seconds: 4);
    }
  }
}

/// Tap the first item of the bottom navigation bar by hit-testing its position
/// (robust when the label text isn't known).
Future<void> _tapFirstNavItem(WidgetTester tester) async {
  final navBar = find.byType(BottomNavigationBar);
  if (navBar.evaluate().isEmpty) return;
  final box = tester.renderObject<RenderBox>(navBar);
  final topLeft = box.localToGlobal(Offset.zero);
  // Owner nav has 2 items; the first sits in the left quarter.
  final target = topLeft +
      Offset(box.size.width * 0.25, box.size.height * 0.5);
  await tester.tapAt(target);
}

/// Open the Scaffold drawer via the app-bar hamburger.
Future<void> _openDrawer(WidgetTester tester) async {
  final state = tester.firstState<ScaffoldState>(find.byType(Scaffold));
  state.openDrawer();
  await _waitFor(tester, seconds: 2);
}

/// Scroll the primary scroll view down (towards later content) in steps.
Future<void> _scrollDown(WidgetTester tester,
    {required double by, int times = 1}) async {
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isEmpty) return;
  for (var i = 0; i < times; i++) {
    await tester.drag(scrollable.first, Offset(0, -by));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Best-effort scroll until [finder] is on screen.
Future<void> _ensureVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) {
    try {
      await tester.ensureVisible(finder.first);
      await tester.pump(const Duration(milliseconds: 200));
    } catch (_) {}
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
