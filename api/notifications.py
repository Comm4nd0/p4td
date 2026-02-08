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
