import firebase_admin
from firebase_admin import credentials, messaging
import os
from django.conf import settings
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

def send_push_notification(user, title, body, data=None):
    """Sends a push notification to all devices registered for a specific user."""
    if not initialize_firebase():
        return
        
    tokens = DeviceToken.objects.filter(user=user).values_list('token', flat=True)
    if not tokens:
        return

    # Create message
    message = messaging.MulticastMessage(
        notification=messaging.Notification(
            title=title,
            body=body,
        ),
        data=data or {},
        tokens=list(tokens),
    )

    try:
        response = messaging.send_multicast(message)
        print(f"Successfully sent {response.success_count} messages; "
              f"failed {response.failure_count} messages.")
        
        # Optionally cleanup invalid tokens
        if response.failure_count > 0:
            for idx, resp in enumerate(response.responses):
                if not resp.success:
                    # Token might be invalid/expired
                    token = tokens[idx]
                    print(f"Failed to send to token {token[:10]}...: {resp.exception}")
                    # DeviceToken.objects.filter(token=token).delete()
    except Exception as e:
        print(f"Error sending push notification: {e}")

def notify_new_post(post):
    """Notify all users (except uploader) about a new post."""
    from django.contrib.auth.models import User
    
    title = "New Post"
    uploader_name = post.uploaded_by.first_name if post.uploaded_by.first_name else post.uploaded_by.username
    body = f"{uploader_name} shared a new {post.media_type.lower()}."
    
    data = {
        'type': 'new_post',
        'post_id': str(post.id),
    }
    
    # In a real app, you might want to filter users or check preferences
    users = User.objects.exclude(id=post.uploaded_by.id)
    for user in users:
        send_push_notification(user, title, body, data)

def send_traffic_alert(alert_type, date, staff_member, detail=''):
    """
    Send a traffic delay notification to owners whose dogs are assigned
    to the given staff member on the given date (i.e. on their route).
    alert_type: 'pickup' or 'dropoff'
    detail: optional extra context from the staff member
    """
    from .models import DailyDogAssignment
    from django.contrib.auth.models import User

    # Only notify owners on this staff member's route whose dogs are
    # still awaiting the relevant action (pickup or dropoff).
    if alert_type == 'pickup':
        relevant_statuses = ['ASSIGNED']
    else:
        relevant_statuses = ['PICKED_UP', 'AT_DAYCARE']

    assignments = DailyDogAssignment.objects.filter(
        date=date, staff_member=staff_member, status__in=relevant_statuses
    ).select_related('dog__owner').prefetch_related('dog__additional_owners')
    owner_ids = set()
    for assignment in assignments:
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
        send_push_notification(owner, title, body, data)


def notify_post_comment(comment, post):
    """
    Notify relevant users when someone comments on a GroupMedia post.
    - The staff member who uploaded the post gets notified of every new comment.
    - Any user who has previously commented on the same post gets notified
      of new replies (thread subscription).
    The commenter themselves is excluded from all notifications.
    """
    from .models import Comment
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
        send_push_notification(user, title, body, data)


def send_staff_notification(title, body, data=None):
    """Sends a push notification to the staff_notifications topic."""
    if not initialize_firebase():
        return

    message = messaging.Message(
        notification=messaging.Notification(
            title=title,
            body=body,
        ),
        data=data or {},
        topic='staff_notifications',
    )

    try:
        response = messaging.send(message)
        print(f"Successfully sent staff notification: {response}")
    except Exception as e:
        print(f"Error sending staff notification: {e}")
