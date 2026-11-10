import 'package:flutter/material.dart';
import 'constants/app_colors.dart';
import 'screens/app_lock_screen.dart';
import 'screens/home_screen.dart';
import 'screens/landing_screen.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';
import 'services/biometric_service.dart';
import 'services/connectivity_status.dart';
import 'services/http_client.dart' as http;
import 'services/theme_service.dart';
import 'services/cache_service.dart';
import 'services/service_locator.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/notification_service.dart';
import 'widgets/offline_banner.dart';
import 'widgets/privacy_cover.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // If you're going to use other Firebase services in the background, such as Firestore,
  // make sure you call `initializeApp` before using other Firebase services.
  await Firebase.initializeApp();
  debugPrint("Handling a background message: ${message.messageId}");
}

final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register services in the locator (idempotent).
  setupLocator();

  // If the server ever rejects the auth token (HTTP 401), sign out and return
  // to the login screen so an invalidated/rotated token can't leave the app
  // permanently stuck (F3). 403 ("authenticated but not permitted") is handled
  // by http_client as a normal response, not an auth failure.
  http.onUnauthorized = (rejectedToken) async {
    // AuthService decides whether this 401 means anything: an anonymous
    // request (browsing the logged-out landing page) does not, and neither
    // does a late answer for an account that has already been signed out —
    // several requests are in flight at once, and on a shared phone the
    // second 401 used to sign out the account promoted by the first.
    // Only the rejected account goes; logoutAll() would knock out every
    // saved account for one expired session.
    final result = await AuthService().handleRejectedToken(rejectedToken);
    if (!result.handled) return;
    final next = result.next;
    // Fully signed out: drop the lock so the login screen isn't sitting
    // behind an unlock prompt for a session that no longer exists.
    if (next == null) getIt<BiometricService>().resetForSignOut();
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => next == null ? const LoginScreen() : const HomeScreen(),
      ),
      (route) => false,
    );
  };

  // Every way out of an account takes this phone's push token off it first,
  // so a signed-out phone stops receiving that person's notifications.
  AuthService.onBeforeSignOut = () => NotificationService().deregisterToken();

  // While offline, periodically probe the server so the app flips back online
  // (and refreshes stale cached screens) as soon as signal returns, rather
  // than waiting for the user to trigger a request. Any response — even an
  // error status — marks the server reachable via the http wrapper.
  ConnectivityStatus().onProbe = () async {
    await http.head(Uri.parse(AuthService.baseUrl),
        timeout: const Duration(seconds: 5));
  };

  // Nothing below may stop the app from starting. Each of these reads the
  // device's secure store or disk, and each has left a phone on the splash
  // screen before now when that read threw (a restored backup whose keystore
  // key did not come with it). The services pick their own safe fallback —
  // no cache, default theme, lock *on* — and these catches are the backstop.

  // Initialize local cache
  try {
    await getIt<CacheService>().init();
  } catch (e) {
    debugPrint('Cache initialization failed: $e. Running without a cache.');
  }

  // Load persisted theme preference
  try {
    await getIt<ThemeService>().init();
  } catch (e) {
    debugPrint('Theme initialization failed: $e. Using the default theme.');
  }

  // Load the app-lock preference before the first frame — if the lock is on,
  // the app must come up already locked rather than flashing the dashboard.
  try {
    await getIt<BiometricService>().init();
  } catch (e) {
    debugPrint('App lock initialization failed: $e.');
  }

  // Try initializing Firebase, but catch errors if config files are missing
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    await getIt<NotificationService>().initialize();
  } catch (e) {
    debugPrint("Firebase initialization failed: $e. Config files might be missing.");
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final _authService = getIt<AuthService>();
  final _themeService = getIt<ThemeService>();
  final _biometrics = getIt<BiometricService>();
  Future<String?>? _tokenFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tokenFuture = _authService.getToken();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Two separate concerns share this callback:
    //
    // 1. The privacy cover goes up at the *first* sign of leaving the
    //    foreground (`inactive`), because that fires before the OS takes its
    //    task-switcher snapshot. The service ignores it while its own auth
    //    prompt is on screen, which also drives the app inactive.
    // 2. The re-lock clock only starts on a genuine `paused`, so pulling down
    //    the notification shade doesn't count as backgrounding.
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _biometrics.obscure();
      case AppLifecycleState.paused:
        _biometrics.obscure();
        _biometrics.noteBackgrounded();
      case AppLifecycleState.resumed:
        _biometrics.lockIfExpired();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themeService,
      builder: (context, _) => MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'Paws 4 Thought Dogs',
        theme: AppColors.lightTheme(),
        darkTheme: AppColors.darkTheme(),
        themeMode: _themeService.themeMode,
        navigatorObservers: [routeObserver],
        // The lock is an overlay rather than a replacement for `child` so the
        // app's Navigator stays mounted underneath — unlocking returns the user
        // to exactly the screen they left, with no route or state rebuilt.
        builder: (context, child) => ListenableBuilder(
          listenable: _biometrics,
          builder: (context, _) => Stack(
            children: [
              Column(
                children: [
                  const OfflineBanner(),
                  Expanded(child: child ?? const SizedBox.shrink()),
                ],
              ),
              if (_biometrics.isLocked)
                const Positioned.fill(child: AppLockScreen())
              else if (_biometrics.isObscured)
                const Positioned.fill(child: PrivacyCover()),
            ],
          ),
        ),
        home: FutureBuilder<String?>(
          future: _tokenFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }

            if (snapshot.hasData && snapshot.data != null) {
              return const HomeScreen();
            } else {
              return const LandingScreen();
            }
          },
        ),
      ),
    );
  }
}
