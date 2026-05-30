import 'package:flutter/material.dart';
import 'constants/app_colors.dart';
import 'screens/home_screen.dart';
import 'screens/landing_screen.dart';
import 'services/auth_service.dart';
import 'services/theme_service.dart';
import 'services/cache_service.dart';
import 'services/service_locator.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/notification_service.dart';

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

  // Initialize local cache
  await getIt<CacheService>().init();

  // Load persisted theme preference
  await getIt<ThemeService>().init();

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

class _MyAppState extends State<MyApp> {
  final _authService = getIt<AuthService>();
  final _themeService = getIt<ThemeService>();
  Future<String?>? _tokenFuture;

  @override
  void initState() {
    super.initState();
    _tokenFuture = _authService.getToken();
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
