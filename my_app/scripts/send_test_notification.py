import firebase_admin
from firebase_admin import credentials, messaging
import sys
import os

def send_test_notification(service_account_path):
    # Initialize Firebase Admin SDK
    try:
        cred = credentials.Certificate(service_account_path)
        # Check if already initialized to avoid error
        if not firebase_admin._apps:
            firebase_admin.initialize_app(cred)
    except Exception as e:
        print(f"Error initializing Firebase: {e}")
        return

    # Create the message
    message = messaging.Message(
        notification=messaging.Notification(
            title='Test Staff Notification',
            body='This is a test message for the staff_notifications topic.',
        ),
        topic='staff_notifications',
    )

    # Send the message
    try:
        response = messaging.send(message)
        print(f"Successfully sent message: {response}")
    except Exception as e:
        print(f"Error sending message: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python send_test_notification.py <path_to_service_account_json>")
        print("Please download your Firebase Admin SDK service account key from:")
        print("Project Settings -> Service accounts -> Generate new private key")
        sys.exit(1)

    service_account_path = sys.argv[1]
    if not os.path.exists(service_account_path):
        print(f"Error: File not found at {service_account_path}")
        sys.exit(1)

    send_test_notification(service_account_path)
