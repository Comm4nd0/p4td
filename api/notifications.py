import firebase_admin
from firebase_admin import credentials, messaging
import logging
import os
from datetime import datetime
from zoneinfo import ZoneInfo

from .models import DeviceToken

logger = logging.getLogger(__name__)

_firebase_app = None


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


def _user_has_preference(user, category):
    """Check whether the user has the given notification category enabled.

    category must be one of: 'feed', 'traffic', 'bookings', 'dog_updates'.
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


def send_push_notification(user, title, body, data=None, category=None):
    """Sends a push notification to all devices registered for a specific user.

    If *category* is supplied the user's notification preferences are checked
    first.  When the preference is disabled the notification is silently
    skipped.

    Staff members are skipped on days they are not working (per their weekly
    availability or approved day-off requests).
    """
    if not _user_has_preference(user, category):
        return

    if user.is_staff and not _is_staff_working_today(user):
        return

    if not initialize_firebase():
        return

    def _dispatch():
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
    # the surrounding DB transaction commits AND on a background daemon thread,
    # so a slow FCM endpoint cannot stall the worker. When there is no active
    # transaction, on_commit runs the callback immediately, which is fine.
    from django.db import transaction
    import threading
    transaction.on_commit(lambda: threading.Thread(target=_dispatch, daemon=True).start())

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
    commenter_name = commenter.first_name or commenter.username
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


def send_staff_notification(title, body, data=None, permission=None):
    """Sends a push notification to staff members individually.

    Unlike the previous topic-based approach, this sends to each staff member
    separately so that work-hours and working-day filters can be applied.

    If *permission* is supplied (e.g. ``'can_manage_requests'``), only staff
    whose UserProfile has that flag set to True will receive the notification.
    When omitted, all staff members are notified.
    """
    from django.contrib.auth.models import User

    filters = {'is_staff': True}
    if permission:
        filters[f'profile__{permission}'] = True

    for user in User.objects.filter(**filters):
        send_push_notification(user, title, body, data)
