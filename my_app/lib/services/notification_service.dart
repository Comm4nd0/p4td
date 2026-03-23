import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'data_service.dart';
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

  Future<void> initialize() async {
    if (_isInitialized) return;

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
        print('User granted permission');
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
          print('Notification tapped with payload: ${response.payload}');
        }
        _handleNotificationTap(response.payload);
      },
    );

    // 3. Handle foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (kDebugMode) {
        print('Got a message whilst in the foreground!');
      }
      _showLocalNotification(message);
    });

    // 4. Handle notification taps when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      if (kDebugMode) {
        print('Notification opened app from background: ${message.data}');
      }
      _handleNotificationTapFromData(message.data);
    });

    // 5. Handle notification tap that launched the app from terminated state
    RemoteMessage? initialMessage = await _fcm.getInitialMessage();
    if (initialMessage != null) {
      if (kDebugMode) {
        print('App launched from notification: ${initialMessage.data}');
      }
      // Delay slightly to let the widget tree build
      Future.delayed(const Duration(milliseconds: 500), () {
        _handleNotificationTapFromData(initialMessage.data);
      });
    }

    // 6. Listen for token refresh and re-register with backend
    _fcm.onTokenRefresh.listen((newToken) {
      if (kDebugMode) {
        print('FCM token refreshed: $newToken');
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
      String? apnsToken = await _fcm.getAPNSToken();
      if (apnsToken != null) {
        if (kDebugMode) {
          print('APNs Token: $apnsToken');
        }
      } else {
        if (kDebugMode) {
          print('APNs Token is NULL');
        }
      }
      String? token = await _fcm.getToken();
      if (token != null) {
        if (kDebugMode) {
          print('FCM Token: $token');
        }
        String deviceType = Platform.isIOS ? 'IOS' : 'ANDROID';
        await _dataService.registerDeviceToken(token, deviceType);
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error updating FCM token: $e');
      }
    }
  }

  /// Handle tap from local notification payload (stringified map)
  void _handleNotificationTap(String? payload) {
    if (payload == null || payload.isEmpty) return;
    if (kDebugMode) {
      print('Handling notification tap with payload: $payload');
    }

    // Parse the stringified map payload: {type: post_comment, post_id: 123}
    final data = _parsePayload(payload);
    if (data != null) {
      _handleNotificationTapFromData(data);
    }
  }

  /// Handle tap from FCM message data (already a Map)
  void _handleNotificationTapFromData(Map<String, dynamic> data) {
    if (kDebugMode) {
      print('Navigating for notification data: $data');
    }

    final type = data['type'] as String?;
    final context = navigatorKey.currentContext;
    if (context == null) return;

    switch (type) {
      // Feed comments — scroll to the specific post
      case 'post_comment':
        final postId = data['post_id'] as String?;
        if (postId != null) {
          _navigateToHome(scrollToPostId: postId);
        }
        break;

      // Date change & boarding requests — open the requests screen (staff)
      case 'date_change_request':
      case 'boarding_request':
      case 'date_change_request_update':   // owner gets status update
        _navigateToHome(initialRoute: 'requests');
        break;

      // Boarding request status (for owners) — open their boarding list
      case 'boarding_request_update':
        _navigateToHome(initialRoute: 'boarding_requests');
        break;

      // Support queries — open the queries screen
      case 'support_query':            // staff: new query from owner
      case 'support_query_update':     // staff: owner replied
      case 'support_query_reply':      // owner: staff replied
        _navigateToHome(initialRoute: 'queries');
        break;

      // Dog status changes — navigate to the specific dog or dogs tab
      case 'dog_status_update':
      case 'care_instructions_update':
        _navigateToHome(initialRoute: 'dogs', routePayload: data['dog_id'] as String?);
        break;

      // Traffic alerts — open dogs tab
      case 'traffic_alert':
        _navigateToHome(initialRoute: 'dogs');
        break;

      // Contact form inquiries — open inquiries screen
      case 'contact_inquiry':
        _navigateToHome(initialRoute: 'inquiries');
        break;

      default:
        // For unknown types, just open the app (already done by tapping)
        break;
    }
  }

  void _navigateToHome({String? scrollToPostId, String? initialRoute, String? routePayload}) {
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => HomeScreen(
          scrollToPostId: scrollToPostId,
          initialRoute: initialRoute,
          routePayload: routePayload,
        ),
      ),
      (route) => false,
    );
  }

  /// Parse a Dart Map.toString() payload back into a Map.
  /// e.g. "{type: post_comment, post_id: 42}" → {type: post_comment, post_id: 42}
  Map<String, dynamic>? _parsePayload(String payload) {
    try {
      // Remove outer braces
      var inner = payload.trim();
      if (inner.startsWith('{') && inner.endsWith('}')) {
        inner = inner.substring(1, inner.length - 1);
      }
      final map = <String, dynamic>{};
      for (final pair in inner.split(', ')) {
        final idx = pair.indexOf(': ');
        if (idx != -1) {
          map[pair.substring(0, idx).trim()] = pair.substring(idx + 2).trim();
        }
      }
      return map.isNotEmpty ? map : null;
    } catch (e) {
      if (kDebugMode) {
        print('Failed to parse notification payload: $e');
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
        payload: message.data.toString(),
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
      print('Subscribed to topic: $topic');
    }
  }

  Future<void> unsubscribeFromTopic(String topic) async {
    await _fcm.unsubscribeFromTopic(topic);
    if (kDebugMode) {
      print('Unsubscribed from topic: $topic');
    }
  }
}
