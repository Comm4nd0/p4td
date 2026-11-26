import 'package:flutter_test/flutter_test.dart';

import 'package:paws4thoughtdogs/screens/home_screen.dart';
import 'package:paws4thoughtdogs/services/notification_routes.dart';

void main() {
  group('notificationDestination', () {
    // Every `type` the server pushes to a client (api/notifications.py,
    // api/views.py, api/billing.py, api/scheduling.py and the reminder
    // commands). A type missing from the app opens the Dashboard with nothing
    // about the notification on it.
    const clientPushes = <Map<String, dynamic>>[
      {'type': 'feed_post', 'post_id': '3125'},
      {'type': 'post_comment', 'post_id': '2999', 'comment_id': '7'},
      {'type': 'dog_status_update', 'dog_id': '137', 'status': 'PICKED_UP'},
      {'type': 'care_instructions_update', 'dog_id': '137'},
      {'type': 'dog_photo', 'dog_id': '137', 'photo_id': '9'},
      {'type': 'dog_profile_change_approved', 'id': '4', 'dog_id': '137'},
      {'type': 'dog_profile_change_rejected', 'id': '4', 'dog_id': '137'},
      {'type': 'schedule_reminder', 'date': '2026-11-27', 'dog_id': '137'},
      {'type': 'waitlist_spot', 'date': '2026-11-27', 'dog_id': '137'},
      {'type': 'date_change_request_update', 'id': '792'},
      {'type': 'boarding_request_update', 'id': '12'},
      {'type': 'intake_request_update', 'id': '3'},
      {'type': 'dog_link_request_update', 'approved': 'true', 'dog_id': '137'},
      {'type': 'dog_link_request_update', 'approved': 'false'},
      {'type': 'support_query_reply', 'id': '68'},
      {'type': 'vaccination', 'dog_id': '137'},
      {'type': 'vaccination_certificate', 'dog_id': '137'},
      {'type': 'traffic_alert'},
      {'type': 'invoice', 'id': '21'},
      {'type': 'invoice_payment', 'id': '21'},
    ];

    for (final data in clientPushes) {
      test('${data['type']} opens a screen', () {
        expect(notificationDestination(data), isNotNull);
      });
    }

    test('an extra-day reminder opens the calendar on its day', () {
      final destination = notificationDestination(
          {'type': 'schedule_reminder', 'date': '2026-11-27', 'dog_id': '137'})!;
      expect(destination.initialRoute, 'schedule_reminder');
      expect(destination.routePayload, '2026-11-27');
    });

    test('a waitlist space opens the calendar on its day', () {
      final destination =
          notificationDestination({'type': 'waitlist_spot', 'date': '2026-12-04', 'dog_id': '1'})!;
      expect(destination.initialRoute, 'schedule_reminder');
      expect(destination.routePayload, '2026-12-04');
    });

    test('a feed push carries its post and no route', () {
      final destination = notificationDestination({'type': 'feed_post', 'post_id': '3125'})!;
      expect(destination.scrollToPostId, '3125');
      expect(destination.initialRoute, isNull);
    });

    test('a decided profile change opens the dog', () {
      final destination = notificationDestination(
          {'type': 'dog_profile_change_approved', 'id': '4', 'dog_id': '137'})!;
      expect(destination.initialRoute, 'dogs');
      expect(destination.routePayload, '137');
    });

    test('an unknown type opens nothing', () {
      expect(notificationDestination({'type': 'something_new'}), isNull);
      expect(notificationDestination({}), isNull);
    });
  });

  group('HomeScreen.opensOnDashboard', () {
    test('a plain launch lands on the Dashboard', () {
      expect(const HomeScreen().opensOnDashboard, isTrue);
    });

    test('a feed push stays on the feed', () {
      expect(const HomeScreen(scrollToPostId: '3125').opensOnDashboard, isFalse);
    });

    test('schedule pushes open the Dashboard, other routes do not', () {
      expect(
          const HomeScreen(initialRoute: 'schedule_reminder', routePayload: '2026-11-27')
              .opensOnDashboard,
          isTrue);
      expect(const HomeScreen(initialRoute: 'queries').opensOnDashboard, isFalse);
    });
  });

  group('NotificationTapInbox', () {
    test('holds a tap that arrives before the app is up, then delivers it', () {
      final opened = <Map<String, dynamic>>[];
      final inbox = NotificationTapInbox(opened.add);

      inbox.add({'type': 'schedule_reminder', 'date': '2026-11-27'});
      expect(opened, isEmpty);

      inbox.markReady();
      expect(opened, [
        {'type': 'schedule_reminder', 'date': '2026-11-27'}
      ]);
    });

    test('delivers once: a second markReady opens nothing more', () {
      final opened = <Map<String, dynamic>>[];
      final inbox = NotificationTapInbox(opened.add);
      inbox.add({'type': 'invoice', 'id': '1'});
      inbox.markReady();
      inbox.markReady();
      expect(opened, hasLength(1));
    });

    test('passes taps straight through once ready', () {
      final opened = <Map<String, dynamic>>[];
      final inbox = NotificationTapInbox(opened.add)..markReady();
      expect(opened, isEmpty);

      inbox.add({'type': 'feed_post', 'post_id': '5'});
      expect(opened, hasLength(1));
    });

    test('keeps only the newest tap while waiting', () {
      final opened = <Map<String, dynamic>>[];
      final inbox = NotificationTapInbox(opened.add);
      inbox.add({'type': 'invoice', 'id': '1'});
      inbox.add({'type': 'invoice', 'id': '2'});
      inbox.markReady();
      expect(opened.single['id'], '2');
    });
  });
}
