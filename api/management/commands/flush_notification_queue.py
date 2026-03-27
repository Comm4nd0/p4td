from django.core.management.base import BaseCommand
from django.utils.timezone import now as tz_now

from api.models import QueuedNotification
from api.notifications import (
    _is_staff_working_today,
    _user_has_preference,
    initialize_firebase,
    DeviceToken,
)
from firebase_admin import messaging


class Command(BaseCommand):
    help = 'Send queued staff notifications whose scheduled time has arrived.'

    def handle(self, *args, **options):
        pending = QueuedNotification.objects.filter(
            scheduled_for__lte=tz_now(),
        ).select_related('user')

        if not pending.exists():
            self.stdout.write('No queued notifications to send.')
            return

        if not initialize_firebase():
            self.stderr.write('Firebase not initialised — aborting.')
            return

        sent = 0
        skipped = 0
        failed = 0

        for queued in pending:
            user = queued.user

            # Re-check: is the staff member working today?
            if user.is_staff and not _is_staff_working_today(user):
                queued.delete()
                skipped += 1
                continue

            # Re-check user preference
            if queued.category and not _user_has_preference(user, queued.category):
                queued.delete()
                skipped += 1
                continue

            tokens = list(
                DeviceToken.objects.filter(user=user).values_list('token', flat=True)
            )
            if not tokens:
                queued.delete()
                skipped += 1
                continue

            for token in tokens:
                message = messaging.Message(
                    notification=messaging.Notification(
                        title=queued.title,
                        body=queued.body,
                    ),
                    data=queued.data or {},
                    token=token,
                )
                try:
                    messaging.send(message)
                    sent += 1
                except (messaging.UnregisteredError, messaging.SenderIdMismatchError):
                    DeviceToken.objects.filter(token=token).delete()
                    failed += 1
                except Exception as e:
                    self.stderr.write(f'Failed to send to {token[:10]}...: {e}')
                    failed += 1

            queued.delete()

        self.stdout.write(
            f'Done. Sent: {sent}, Skipped: {skipped}, Failed: {failed}'
        )
