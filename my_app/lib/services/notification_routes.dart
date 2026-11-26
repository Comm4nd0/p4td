/// Where a tapped push opens the app, and the holding place for a tap that
/// arrives before the app can go anywhere. Kept free of Firebase and widgets
/// so both can be tested.
library;

/// The [HomeScreen] arguments a tapped push resolves to.
class NotificationDestination {
  /// Open the feed on this post.
  final String? scrollToPostId;

  /// One of the routes `HomeScreen._handleInitialRoute` knows.
  final String? initialRoute;

  /// The id or date the route is about.
  final String? routePayload;

  const NotificationDestination({this.scrollToPostId, this.initialRoute, this.routePayload});
}

/// The screen a push's data payload opens, or null when tapping it should
/// only bring the app forward. Every push a client can receive must have an
/// entry here: a tap that lands on the Dashboard with no trace of what the
/// notification said reads as "there is nothing there".
NotificationDestination? notificationDestination(Map<String, dynamic> data) {
  String? value(String key) => data[key]?.toString();

  final type = value('type');
  switch (type) {
    // Feed comments, and new posts tagged with one of your dogs — the feed,
    // on that post.
    case 'post_comment':
    case 'feed_post':
      final postId = value('post_id');
      return postId == null ? null : NotificationDestination(scrollToPostId: postId);

    // Date change & boarding requests — the requests screen (staff). The
    // request id lets Home open the right dog for an owner with several;
    // staff ignore it and get the Requests screen.
    case 'date_change_request':
    case 'boarding_request':
    case 'date_change_request_update': // owner gets status update
      return NotificationDestination(initialRoute: 'requests', routePayload: value('id'));

    // Boarding request status (for owners) — their boarding list.
    case 'boarding_request_update':
      return const NotificationDestination(initialRoute: 'boarding_requests');

    // Booking forms — staff: new submission to review; owner: status update.
    case 'intake_request':
    case 'intake_request_update':
      return const NotificationDestination(initialRoute: 'booking_forms');

    // Day off — a manager: someone has asked; staff: their answer. Both open
    // My Availability on Time Off.
    case 'day_off_request':
    case 'day_off_decision':
    case 'day_off_request_update':
      return const NotificationDestination(initialRoute: 'day_off');

    // Link my dog — staff: new request to match; owner: the dog is now on
    // their account (open it) or the request was denied (show why).
    case 'dog_link_request':
      return const NotificationDestination(initialRoute: 'booking_forms');
    case 'dog_link_request_update':
      return value('approved') == 'true'
          ? NotificationDestination(initialRoute: 'dogs', routePayload: value('dog_id'))
          : const NotificationDestination(initialRoute: 'booking_forms');

    // Support queries — the queries screen.
    case 'support_query': // staff: new query from owner
    case 'support_query_update': // staff: owner replied
    case 'support_query_reply': // owner: staff replied
      return const NotificationDestination(initialRoute: 'queries');

    // Anything about one dog — collected/home, a new gallery photo, care
    // instructions, a profile change staff have decided — opens that dog.
    case 'dog_status_update':
    case 'care_instructions_update':
    case 'dog_photo':
    case 'dog_profile_change_approved':
    case 'dog_profile_change_rejected':
      return NotificationDestination(initialRoute: 'dogs', routePayload: value('dog_id'));

    // Vaccination reminders — owner: the dog's vaccinations screen, and
    // straight into the attach sheet when it is the certificate being
    // chased (the daily cadence and a staff member's Send reminder).
    case 'vaccination':
      return NotificationDestination(initialRoute: 'vaccinations', routePayload: value('dog_id'));
    case 'vaccination_certificate':
      return NotificationDestination(
          initialRoute: 'vaccination_certificate', routePayload: value('dog_id'));

    // Traffic alerts — the dogs tab.
    case 'traffic_alert':
      return const NotificationDestination(initialRoute: 'dogs');

    // Changes to the routine, opened on the day they are about. Staff (the
    // 18:00 summary and late changes) get the dashboard on that date, with
    // its Changes section; owners (an extra-day / day-off reminder) get My
    // Calendar on that day.
    case 'schedule_change':
    case 'schedule_reminder':
      return NotificationDestination(initialRoute: type, routePayload: value('date'));

    // A waitlisted day has a space — My Calendar on that day, where the
    // owner can see it and request it.
    case 'waitlist_spot':
      return NotificationDestination(initialRoute: 'schedule_reminder', routePayload: value('date'));

    // Incidents — staff only (the incident log is never shown to owners);
    // HomeScreen drops the route for anyone who isn't staff.
    case 'incident':
      return NotificationDestination(initialRoute: 'incident', routePayload: value('id'));

    // Contact form inquiries — the inquiries screen.
    case 'contact_inquiry':
      return const NotificationDestination(initialRoute: 'inquiries');

    // Invoices — owner: invoice sent/receipt/reminder; staff payment
    // managers land on the customer payments screen instead (HomeScreen
    // decides based on permissions).
    case 'invoice':
    case 'invoice_payment':
      return NotificationDestination(initialRoute: 'payments', routePayload: value('id'));

    // Monthly drafts ready — staff review prompt.
    case 'invoices_generated':
      return const NotificationDestination(initialRoute: 'customer_payments');

    default:
      // Unknown types just open the app (already done by tapping).
      return null;
  }
}

/// Holds a notification tap until the app can act on it.
///
/// A tap that launches the app from closed is known before the first frame
/// exists, so there is no Navigator to open anything on yet. The tap waits
/// here and is delivered the moment [markReady] is called; once ready, taps
/// pass straight through. Only the newest tap is kept — there is one screen
/// to open.
class NotificationTapInbox {
  NotificationTapInbox(this._deliver);

  final void Function(Map<String, dynamic> data) _deliver;
  bool _ready = false;
  Map<String, dynamic>? _held;

  bool get isReady => _ready;

  void add(Map<String, dynamic> data) {
    if (_ready) {
      _deliver(data);
    } else {
      _held = data;
    }
  }

  void markReady() {
    _ready = true;
    final held = _held;
    _held = null;
    if (held != null) _deliver(held);
  }
}
