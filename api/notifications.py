import firebase_admin
from firebase_admin import credentials, messaging
import os
from datetime import datetime
from zoneinfo import ZoneInfo

from .models import DeviceToken

_firebase_app = None


def initialize_firebase():
    global _firebase_app
    if _firebase_app:
        return True

    # Path to your service account key file
    cred_path = os.environ.get('FIREBASE_SERVICE_ACCOUNT_KEY')
    if not cred_path or not os.path.exists(cred_path):
        print("Firebase service account key not found. Push notifications will be disabled.")
        return False

    try:
        cred = credentials.Certificate(cred_path)
        _firebase_app = firebase_admin.initialize_app(cred)
        return True
    except Exception as e:
        print(f"Error initializing Firebase Admin: {e}")
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

    tokens = list(DeviceToken.objects.filter(user=user).values_list('token', flat=True))
    if not tokens:
        return

    # Send to each token individually using the current firebase-admin API
    success_count = 0
    failure_count = 0
    for token in tokens:
        message = messaging.Message(
            notification=messaging.Notification(
                title=title,
                body=body,
            ),
            data=data or {},
            token=token,
        )
        try:
            messaging.send(message)
            success_count += 1
        except (messaging.UnregisteredError, messaging.SenderIdMismatchError):
            # Token is invalid or registered to a different sender - clean it up
            DeviceToken.objects.filter(token=token).delete()
            failure_count += 1
            print(f"Removed stale token {token[:10]}...")
        except Exception as e:
            failure_count += 1
            print(f"Failed to send to token {token[:10]}...: {e}")

    print(f"Successfully sent {success_count} messages; failed {failure_count} messages.")

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

    # Only notify owners on this staff member's route whose dogs are
    # still awaiting the relevant action (pickup or dropoff).
    if alert_type == 'pickup':
        relevant_statuses = ['ASSIGNED']
    else:
        relevant_statuses = ['PICKED_UP']

    assignments = DailyDogAssignment.objects.filter(
        date=date, staff_member=staff_member, status__in=relevant_statuses
    ).select_related('dog__owner').prefetch_related('dog__additional_owners')

    # If specific dogs were selected, filter to only those
    if dog_ids:
        assignments = assignments.filter(dog_id__in=dog_ids)

    # Skip dogs where the owner is handling this leg of transport —
    # they don't need a staff traffic delay alert.
    owner_ids = set()
    for assignment in assignments:
        if alert_type == 'pickup' and assignment.effective_owner_brings:
            continue
        if alert_type == 'dropoff' and assignment.effective_owner_collects:
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
