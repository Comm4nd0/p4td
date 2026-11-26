import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'data_service.dart';
import 'notification_routes.dart';
import '../screens/home_screen.dart';
import '../main.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  final DataService _dataService = ApiDataService();

  bool _isInitialized = false;

  /// Every tap goes through here. A tap that launched the app is known
  /// before there is a Navigator; it waits until the first frame is up.
  late final NotificationTapInbox _taps = NotificationTapInbox(_openTappedNotification);

  final StreamController<Map<String, dynamic>> _foregroundMessages =
      StreamController<Map<String, dynamic>>.broadcast();

  /// The data payload of every push that arrives while the app is open.
  /// The home screen listens so the inbox badges beside the bell climb the
  /// moment a message, booking form or enquiry lands, without a restart.
  Stream<Map<String, dynamic>> get foregroundMessages => _foregroundMessages.stream;

  Future<void> initialize() async {
    if (_isInitialized) return;

    // Taps are held until the app is on screen (see step 5). Arranged first
    // so nothing that fails below can leave one held for good.
    _releaseTapsWhenAppIsUp();

    // 1. Request permissions (especially for iOS)
    NotificationSettings settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // 1b. Set foreground presentation options (iOS 10+)
    // This allows heads-up notifications even when the app is open!
    await _fcm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      if (kDebugMode) {
        debugPrint('User granted permission');
      }
    }

    // 2. Initialize local notifications for foreground display
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings();

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );

    await _localNotifications.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        if (kDebugMode) {
          debugPrint('Notification tapped with payload: ${response.payload}');
        }
        _handleNotificationTap(response.payload);
      },
    );

    // 3. Handle foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (kDebugMode) {
        debugPrint('Got a message whilst in the foreground!');
      }
      _showLocalNotification(message);
      _foregroundMessages.add(Map<String, dynamic>.from(message.data));
    });

    // 4. Handle notification taps when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      if (kDebugMode) {
        debugPrint('Notification opened app from background: ${message.data}');
      }
      _taps.add(message.data);
    });

    // 5. Handle notification tap that launched the app from terminated state.
    // This runs before runApp, and the token registration below is a network
    // call that runApp waits behind, so there is no telling how long it is
    // until a Navigator exists. A fixed delay used to stand in for that and
    // lost the tap whenever the call took longer: the app opened on the
    // Dashboard with nothing about the notification. The tap is held and
    // opened once the first frame is up (_releaseTapsWhenAppIsUp).
    RemoteMessage? initialMessage = await _fcm.getInitialMessage();
    if (initialMessage != null) {
      if (kDebugMode) {
        debugPrint('App launched from notification: ${initialMessage.data}');
      }
      _taps.add(initialMessage.data);
    }

    // 6. Listen for token refresh and re-register with backend
    _fcm.onTokenRefresh.listen((newToken) {
      if (kDebugMode) {
        debugPrint('FCM token refreshed: $newToken');
      }
      updateToken();
    });

    // 7. Handle background messages (handled by top-level function in main.dart)

    _isInitialized = true;

    // Refresh token and send to backend
    await updateToken();
  }

  Future<void> updateToken() async {
    try {
      // Registering the device token is an authenticated call, and login /
      // account-switch re-register it anyway. Skipping while signed out
      // avoids an anonymous 401 at startup, which the global 401 handler
      // would treat as an expired session and bounce logged-out visitors
      // off the landing page onto the login screen.
      if (await AuthService().getToken() == null) return;
      String? apnsToken = await _fcm.getAPNSToken();
      if (apnsToken != null) {
        if (kDebugMode) {
          debugPrint('APNs Token: $apnsToken');
        }
      } else {
        if (kDebugMode) {
          debugPrint('APNs Token is NULL');
        }
      }
      String? token = await _fcm.getToken();
      if (token != null) {
        if (kDebugMode) {
          debugPrint('FCM Token: $token');
        }
        String deviceType = Platform.isIOS ? 'IOS' : 'ANDROID';
        await _dataService.registerDeviceToken(token, deviceType);
        // Registered again, so a later sign-out has something to detach.
        _detachedForAuthToken = null;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error updating FCM token: $e');
      }
    }
  }

  /// The auth token of the account this phone's push token was last detached
  /// from. Sign-out detaches in [AuthService] itself now, and the Profile
  /// screen still calls [deregisterToken] first, so the second call for the
  /// same account must cost nothing — on a poor connection it would otherwise
  /// double the wait before the screen changes.
  String? _detachedForAuthToken;

  /// Remove this device's token from the account that is currently signed in,
  /// so the device stops receiving that user's notifications after logout.
  /// Best-effort: must be called while the user is still authenticated.
  /// Safe to call more than once for the same account.
  Future<void> deregisterToken() async {
    try {
      final authToken = await AuthService().getToken();
      if (authToken == null || authToken == _detachedForAuthToken) return;
      String? token = await _fcm.getToken();
      if (token != null) {
        await _dataService.deregisterDeviceToken(token);
        _detachedForAuthToken = authToken;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error deregistering FCM token: $e');
      }
    }
  }

  /// Let held taps through once the app has a Navigator to open them on.
  void _releaseTapsWhenAppIsUp() {
    if (navigatorKey.currentState != null) {
      _taps.markReady();
      return;
    }
    // Not built yet: look again after the next frame. runApp draws one, so
    // this always comes round.
    WidgetsBinding.instance.addPostFrameCallback((_) => _releaseTapsWhenAppIsUp());
  }

  /// Handle tap from local notification payload (stringified map)
  void _handleNotificationTap(String? payload) {
    if (payload == null || payload.isEmpty) return;
    if (kDebugMode) {
      debugPrint('Handling notification tap with payload: $payload');
    }

    // Parse the stringified map payload: {type: post_comment, post_id: 123}
    final data = _parsePayload(payload);
    if (data != null) {
      _taps.add(data);
    }
  }

  /// Open the screen a tapped push is about (see [notificationDestination]).
  Future<void> _openTappedNotification(Map<String, dynamic> data) async {
    if (kDebugMode) {
      debugPrint('Navigating for notification data: $data');
    }

    // A push can outlive the session it was sent to (signed out with no
    // signal, so the phone's token never came off the account). Opening the
    // home screen for it would show a signed-out person an app with no data
    // behind it; leave them on the landing or login screen they are on.
    if (await AuthService().getToken() == null) return;

    final destination = notificationDestination(data);
    if (destination == null) return;

    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => HomeScreen(
          scrollToPostId: destination.scrollToPostId,
          initialRoute: destination.initialRoute,
          routePayload: destination.routePayload,
        ),
      ),
      (route) => false,
    );
  }

  /// Parse a JSON payload (written by jsonEncode(message.data)) back into a Map.
  /// The old Map.toString() format corrupted any value containing ', ' or ': '
  /// (comment previews, punctuated titles) — JSON round-trips them safely (F7).
  Map<String, dynamic>? _parsePayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to parse notification payload: $e');
      }
      return null;
    }
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    RemoteNotification? notification = message.notification;

    if (notification != null && (notification.title != null || notification.body != null)) {
      await _localNotifications.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
        title: notification.title ?? '',
        body: notification.body ?? '',
        payload: jsonEncode(message.data),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'p4td_main_channel',
            'Main Notifications',
            channelDescription: 'Notifications for post updates and requests',
            importance: Importance.max,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    }
  }

  Future<void> subscribeToTopic(String topic) async {
    await _fcm.subscribeToTopic(topic);
    if (kDebugMode) {
      debugPrint('Subscribed to topic: $topic');
    }
  }

  Future<void> unsubscribeFromTopic(String topic) async {
    await _fcm.unsubscribeFromTopic(topic);
    if (kDebugMode) {
      debugPrint('Unsubscribed from topic: $topic');
    }
  }
}
