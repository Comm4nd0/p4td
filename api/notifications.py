import firebase_admin
from firebase_admin import credentials, messaging
import logging
import os
from datetime import datetime
from zoneinfo import ZoneInfo

from .models import DeviceToken

logger = logging.getLogger(__name__)

_firebase_app = None

# Push dispatch used to spawn one unbounded daemon thread per recipient. A
# traffic alert to a 30-dog route, or send_all over a month of invoices, fanned
# out that many threads *and* that many Postgres connections at once, against a
# 2-worker/2-thread web tier and a default max_connections of 100. A small fixed
# pool bounds both; FCM calls are I/O-bound so four is plenty, and work queues
# rather than being dropped.
_push_executor = None
_push_executor_lock = None


def _executor():
    """Lazily-created shared thread pool for FCM dispatch."""
    global _push_executor, _push_executor_lock
    import threading
    if _push_executor_lock is None:
        _push_executor_lock = threading.Lock()
    if _push_executor is None:
        from concurrent.futures import ThreadPoolExecutor
        with _push_executor_lock:
            if _push_executor is None:
                _push_executor = ThreadPoolExecutor(
                    max_workers=4, thread_name_prefix='push')
    return _push_executor


def initialize_firebase():
    global _firebase_app
    if _firebase_app:
        return True

    # Path to your service account key file
    cred_path = os.environ.get('FIREBASE_SERVICE_ACCOUNT_KEY')
    if not cred_path or not os.path.exists(cred_path):
        logger.warning("Firebase service account key not found. Push notifications will be disabled.")
        return False

    try:
        cred = credentials.Certificate(cred_path)
        _firebase_app = firebase_admin.initialize_app(cred)
        return True
    except Exception as e:
        logger.error(f"Error initializing Firebase Admin: {e}", exc_info=True)
        return False


def _is_staff_working_today(user):
    """Check if a staff member is working today based on availability and day-off requests."""
    from .models import StaffAvailability, DayOffRequest

    today = datetime.now(ZoneInfo('Europe/London')).date()
    dow = today.isoweekday()  # 1=Monday ... 7=Sunday

    # Check weekly availability (default to available if no record exists)
    try:
        avail = StaffAvailability.objects.get(staff_member=user, day_of_week=dow)
        if not avail.is_available:
            return False
    except StaffAvailability.DoesNotExist:
        pass

    # Check approved day-off requests
    if DayOffRequest.objects.filter(staff_member=user, date=today, status='APPROVED').exists():
        return False

    return True


def public_display_name(user):
    """The name one client may see for another (or for a staff member).

    Usernames are email addresses (the app signs people up that way), so the
    old ``first_name or username`` fallback put a client's email in front of
    every other client the moment their first name was blank. First names are
    all clients see of each other; anything else gets a neutral label.
    """
    if user is None:
        return 'Dog owner'
    first = (user.first_name or '').strip()
    if first:
        return first
    return 'Paws 4 Thought team' if user.is_staff else 'Dog owner'


def _user_has_preference(user, category):
    """Check whether the user has the given notification category enabled.

    category must be one of: 'feed', 'traffic', 'bookings', 'dog_updates',
    'messages'.
    Returns True when no profile exists (default to sending).
    """
    if category is None:
        return True
    try:
        profile = user.profile
        field = f'notify_{category}'
        return getattr(profile, field, True)
    except Exception:
        return True


def send_push_notification(user, title, body, data=None, category=None,
                           ignore_working_hours=False):
    """Sends a push notification to all devices registered for a specific user.

    If *category* is supplied the user's notification preferences are checked
    first.  When the preference is disabled the notification is silently
    skipped.

    Staff members are skipped on days they are not working (per their weekly
    availability or approved day-off requests), unless *ignore_working_hours*
    is set — used for business-owner oversight alerts, which should arrive
    even on the recipient's day off.
    """
    if not _user_has_preference(user, category):
        return

    if user.is_staff and not ignore_working_hours and not _is_staff_working_today(user):
        return

    if not initialize_firebase():
        return

    def _dispatch():
        # Runs on a pool thread, which gets its own DB connection. Django only
        # closes connections at the end of a *request*, so without the finally
        # below every notification would leak one until Postgres hits
        # max_connections.
        from django.db import connection as _db_connection
        try:
            _dispatch_inner()
        finally:
            _db_connection.close()

    def _dispatch_inner():
        tokens = list(DeviceToken.objects.filter(user=user).values_list('token', flat=True))
        if not tokens:
            return

        # Send to all tokens in a single batched call using the firebase-admin
        # batch API. send_each preserves input order, so responses line up with
        # the messages (and therefore the tokens) by index.
        messages = [
            messaging.Message(
                notification=messaging.Notification(
                    title=title,
                    body=body,
                ),
                data=data or {},
                token=token,
            )
            for token in tokens
        ]

        try:
            batch_response = messaging.send_each(messages)
        except Exception as e:
            logger.error(f"Failed to send push notifications: {e}", exc_info=True)
            return

        success_count = 0
        failure_count = 0
        for token, response in zip(tokens, batch_response.responses):
            if response.success:
                success_count += 1
                continue

            failure_count += 1
            exception = response.exception
            if isinstance(exception, (messaging.UnregisteredError, messaging.SenderIdMismatchError)):
                # Token is invalid or registered to a different sender - clean it up
                DeviceToken.objects.filter(token=token).delete()
                logger.warning(f"Removed stale token {token[:10]}...")
            else:
                logger.error(f"Failed to send to token {token[:10]}...: {exception}")

        logger.info(f"Successfully sent {success_count} messages; failed {failure_count} messages.")

    # Get the Firebase network I/O off the request/transaction path: run after
    # the surrounding DB transaction commits AND on a background worker, so a
    # slow FCM endpoint cannot stall the gunicorn worker. When there is no
    # active transaction, on_commit runs the callback immediately, which is fine.
    from django.db import transaction
    transaction.on_commit(lambda: _executor().submit(_dispatch))

def send_traffic_alert(alert_type, date, staff_member, detail='', dog_ids=None):
    """
    Send a traffic delay notification to owners whose dogs are assigned
    to the given staff member on the given date (i.e. on their route).
    alert_type: 'pickup' or 'dropoff'
    detail: optional extra context from the staff member
    dog_ids: optional list of dog IDs to limit notifications to
    """
    from .models import DailyDogAssignment
    from django.contrib.auth.models import User

    assignments = DailyDogAssignment.objects.filter(
        date=date, staff_member=staff_member
    ).exclude(status__in=['REMOVED', 'UNASSIGNED']).select_related('dog__owner').prefetch_related('dog__additional_owners')

    if dog_ids:
        # An explicit selection from the app is authoritative: notify exactly
        # these dogs regardless of pickup/dropoff status (the app already
        # excluded the dogs that are done).
        assignments = assignments.filter(dog_id__in=dog_ids)
    else:
        # Default: only owners whose dogs are still awaiting the relevant
        # action (pickup → not yet picked up, dropoff → not yet dropped home).
        relevant_statuses = ['ASSIGNED'] if alert_type == 'pickup' else ['PICKED_UP']
        assignments = assignments.filter(status__in=relevant_statuses)

    # Skip dogs with no staff leg to be delayed: the owner is handling this
    # leg, or the dog is mid-boarding (only travels home→staff on the first
    # day of the stay and staff→home on the last).
    owner_ids = set()
    for assignment in assignments:
        if alert_type == 'pickup' and not assignment.needs_staff_pickup:
            continue
        if alert_type == 'dropoff' and not assignment.needs_staff_dropoff:
            continue
        owner_ids.add(assignment.dog.owner_id)
        for additional_owner in assignment.dog.additional_owners.all():
            owner_ids.add(additional_owner.id)

    # Oversight copy to the business owner (profiles flagged
    # receives_business_alerts): who pressed the button, which leg, how many
    # owners it reached. Sent even when nothing reached an owner — the boss
    # still wants to know the button was pressed — and past the working-day
    # filter, so a day off doesn't swallow it.
    staff_name = staff_member.first_name or staff_member.username
    leg = 'pickup' if alert_type == 'pickup' else 'drop-off'
    if owner_ids:
        count = len(owner_ids)
        boss_body = (
            f"{staff_name} sent a {leg} traffic delay alert to "
            f"{count} owner{'s' if count != 1 else ''} on their route."
        )
    else:
        boss_body = (
            f"{staff_name} pressed the {leg} traffic alert button, "
            f"but no owners needed notifying."
        )
    if detail:
        boss_body += f"\n\nDetail: {detail}"
    send_staff_notification(
        "Traffic alert sent",
        boss_body,
        {
            'type': 'traffic_alert_sent',
            'alert_type': alert_type,
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        },
        permission='receives_business_alerts',
        exclude_user=staff_member,
        ignore_working_hours=True,
    )

    if not owner_ids:
        return

    if alert_type == 'pickup':
        title = "Traffic Update"
        body = (
            "There is high traffic in your area so your dog's pickup might be "
            "a little later than usual, but still within the 08:00–10:00 window."
        )
    else:
        title = "Traffic Update"
        body = (
            "There is high traffic in your area so your dog's drop-off might be "
            "a little later than usual, but still within the 15:00–17:00 window."
        )

    if detail:
        body += f"\n\nDetail: {detail}"

    data = {
        'type': 'traffic_alert',
        'alert_type': alert_type,
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
    }

    owners = User.objects.filter(id__in=owner_ids)
    for owner in owners:
        send_push_notification(owner, title, body, data, category='traffic')


def notify_post_comment(comment, post):
    """
    Notify relevant users when someone comments on a GroupMedia post.
    - The staff member who uploaded the post gets notified of every new comment.
    - Any user who has previously commented on the same post gets notified
      of new replies (thread subscription).
    - Any user who has reacted to the post gets notified.
    The commenter themselves is excluded from all notifications.
    """
    from .models import Comment, MediaReaction
    from django.contrib.auth.models import User

    commenter = comment.user
    commenter_name = public_display_name(commenter)
    post_label = post.caption[:50] if post.caption else f"{post.media_type.lower()} post"

    # Collect user IDs to notify (avoid duplicates)
    users_to_notify = set()

    # 1. Notify the post uploader (staff member) if they are not the commenter
    if post.uploaded_by_id != commenter.id:
        users_to_notify.add(post.uploaded_by_id)

    # 2. Notify all previous commenters on this post (thread subscription)
    previous_commenter_ids = (
        Comment.objects.filter(group_media=post)
        .exclude(user=commenter)
        .values_list('user_id', flat=True)
        .distinct()
    )
    users_to_notify.update(previous_commenter_ids)

    # 3. Notify users who have reacted to this post
    reactor_ids = (
        MediaReaction.objects.filter(media=post)
        .exclude(user=commenter)
        .values_list('user_id', flat=True)
        .distinct()
    )
    users_to_notify.update(reactor_ids)

    if not users_to_notify:
        return

    data = {
        'type': 'post_comment',
        'post_id': str(post.id),
        'comment_id': str(comment.id),
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
    }

    users = User.objects.filter(id__in=users_to_notify)
    for user in users:
        # Tailor the message depending on whether they are the post owner or a fellow commenter
        if user.id == post.uploaded_by_id:
            title = "New Comment on Your Post"
            body = f"{commenter_name} commented on your {post_label}."
        else:
            title = "New Reply"
            body = f"{commenter_name} also replied to a post you commented on."
        send_push_notification(user, title, body, data, category='feed')


def _dog_household(dog):
    """Everyone who should hear about a dog: the owner plus co-owners."""
    people = []
    if dog.owner_id:
        people.append(dog.owner)
    people.extend(dog.additional_owners.all())
    return people


def notify_dog_status(assignment, previous_status):
    """Tell the household when their dog is collected or back home.

    Fires when a driver moves a day's assignment to PICKED_UP or DROPPED_OFF.
    The wording follows who does the transport for that day: when the owner
    brings the dog in, PICKED_UP means "arrived at daycare" rather than
    "collected"; when the owner collects, DROPPED_OFF is their own hand-over
    and nothing is sent. Governed by the 'dog_updates' preference, which the
    app has offered ("Picked up, at daycare, dropped off") since before the
    server sent anything for it. Tapping opens the dog in the app.
    """
    new_status = assignment.status
    if new_status == previous_status or new_status not in ('PICKED_UP', 'DROPPED_OFF'):
        return
    dog = assignment.dog
    owner_brings = assignment.owner_brings if assignment.owner_brings is not None else dog.owner_brings_default
    owner_collects = assignment.owner_collects if assignment.owner_collects is not None else dog.owner_collects_default

    if new_status == 'PICKED_UP':
        if owner_brings:
            title = f"{dog.name} has arrived"
            body = f"{dog.name} is checked in with the Paws 4 Thought team."
        else:
            title = f"{dog.name} has been collected"
            body = f"{dog.name} is on board with the Paws 4 Thought team."
    else:
        if owner_collects:
            return
        title = f"{dog.name} is home"
        body = f"{dog.name} has been dropped off at home."

    data = {
        'type': 'dog_status_update',
        'dog_id': str(dog.id),
        'assignment_id': str(assignment.id),
        'status': new_status,
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
    }
    for person in _dog_household(dog):
        send_push_notification(person, title, body, data, category='dog_updates')


def notify_feed_post_tags(post):
    """Tell each tagged dog's household about a new feed post.

    One push per person however many of their dogs are tagged; the uploader is
    skipped. Governed by the 'feed' preference. Typed 'feed_post' so tapping
    opens the feed scrolled to this post.
    """
    poster = public_display_name(post.uploaded_by)
    kind = 'video' if post.media_type == 'VIDEO' else 'photo'
    recipients = {}
    for dog in post.tagged_dogs.all():
        for person in _dog_household(dog):
            if person.id == post.uploaded_by_id:
                continue
            recipients.setdefault(person.id, (person, []))[1].append(dog.name)
    if not recipients:
        return
    data = {
        'type': 'feed_post',
        'post_id': str(post.id),
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
    }
    for person, dog_names in recipients.values():
        names = ' and '.join(dog_names) if len(dog_names) <= 2 else f"{dog_names[0]} and {len(dog_names) - 1} others"
        title = f"New {kind} of {names}"
        body = post.caption.strip()[:120] if post.caption and post.caption.strip() else f"{poster} posted a new {kind} of {names}."
        send_push_notification(person, title, body, data, category='feed')


def notify_support_message(query, sender):
    """Push the other side of a support thread when a message lands.

    A staff reply goes to the client (typed 'support_query_reply'); a client's
    message goes to every staff member who can reply to queries (typed
    'support_query_update'). Both open the queries screen in the app and both
    honour the 'messages' preference — a client can silence replies, and a
    staff member who is not on queries that day can silence the inbox.
    """
    from django.contrib.auth.models import User

    subject = query.subject[:60]
    if sender.is_staff:
        if query.owner_id and query.owner_id != sender.id:
            send_push_notification(
                query.owner,
                'New reply from Paws 4 Thought',
                f"{public_display_name(sender)} replied to '{subject}'.",
                {'type': 'support_query_reply', 'id': str(query.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
                category='messages',
            )
        return
    owner_name = public_display_name(sender)
    for staff in User.objects.filter(is_staff=True, profile__can_reply_queries=True).exclude(id=sender.id):
        send_push_notification(
            staff,
            f"Message from {owner_name}",
            f"'{subject}' has a new message.",
            {'type': 'support_query_update', 'id': str(query.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
            category='messages',
        )


def notify_new_support_query(query):
    """Tell staff who can reply that a client has opened a new thread."""
    from django.contrib.auth.models import User

    owner_name = public_display_name(query.owner)
    for staff in User.objects.filter(is_staff=True, profile__can_reply_queries=True).exclude(id=query.owner_id):
        send_push_notification(
            staff,
            f"New message from {owner_name}",
            query.subject[:100],
            {'type': 'support_query', 'id': str(query.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
            category='messages',
        )


def notify_defect_comment(comment, defect, defect_type='vehicle'):
    """Notify the defect reporter and anyone who previously commented when a new
    progress comment is added. The commenter themselves is always excluded.

    ``defect_type`` is 'vehicle' or 'facility' and drives both the thread lookup
    and the notification's deep-link type.
    """
    from django.contrib.auth.models import User
    from .models import VehicleDefectComment, FacilityDefectComment

    commenter = comment.user
    commenter_name = commenter.first_name or commenter.username

    user_ids = set()
    if defect.reported_by_id and defect.reported_by_id != commenter.id:
        user_ids.add(defect.reported_by_id)

    if defect_type == 'vehicle':
        prior = VehicleDefectComment.objects.filter(defect=defect)
        notif_type = 'vehicle_defect'
    else:
        prior = FacilityDefectComment.objects.filter(defect=defect)
        notif_type = 'facility_defect'
    user_ids.update(
        prior.exclude(user=commenter).values_list('user_id', flat=True).distinct()
    )

    if not user_ids:
        return

    title = f"New comment on '{defect.title}'"
    body = f"{commenter_name}: {comment.text[:120]}"
    data = {
        'type': notif_type,
        'id': str(defect.id),
        'click_action': 'FLUTTER_NOTIFICATION_CLICK',
    }
    for user in User.objects.filter(id__in=user_ids):
        send_push_notification(user, title, body, data)


def send_staff_notification(title, body, data=None, permission=None, exclude_user=None,
                            ignore_working_hours=False):
    """Sends a push notification to staff members individually.

    Unlike the previous topic-based approach, this sends to each staff member
    separately so that work-hours and working-day filters can be applied.

    If *permission* is supplied (e.g. ``'can_manage_requests'``), only staff
    whose UserProfile has that flag set to True will receive the notification.
    When omitted, all staff members are notified.

    *exclude_user* skips one recipient — used so the staff member who caused
    the event (reported the defect, edited the instructions) isn't notified
    about their own action.
    """
    from django.contrib.auth.models import User

    filters = {'is_staff': True}
    if permission:
        filters[f'profile__{permission}'] = True

    recipients = User.objects.filter(**filters)
    if exclude_user is not None:
        recipients = recipients.exclude(pk=exclude_user.pk)

    for user in recipients:
        send_push_notification(user, title, body, data,
                               ignore_working_hours=ignore_working_hours)
