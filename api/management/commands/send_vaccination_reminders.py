"""Send push reminders for vaccinations that are expiring or expired.

Designed to run daily from cron. Each milestone (30 days out, 7 days out,
expired) notifies the dog's owners exactly once — bookkeeping flags on the
record make reruns no-ops. Staff with can_manage_requests get a digest of
newly-expired vaccinations so compliance issues are visible.
"""
from datetime import date, timedelta

from django.contrib.auth.models import User
from django.core.management.base import BaseCommand

from api.models import VaccinationRecord
from api.notifications import send_push_notification
from api.cron_heartbeat import ping_heartbeat


class Command(BaseCommand):
    help = 'Send vaccination expiry reminders to dog owners (run daily).'

    def _notify_owners(self, record, title, body):
        data = {
            'type': 'vaccination',
            'dog_id': str(record.dog_id),
            'record_id': str(record.id),
        }
        recipients = [record.dog.owner] if record.dog.owner else []
        recipients += list(record.dog.additional_owners.all())
        for user in recipients:
            try:
                send_push_notification(user, title, body, data, category='dog_updates')
            except Exception as exc:
                self.stderr.write(f'Failed to notify {user}: {exc}')

    def handle(self, *args, **options):
        today = date.today()
        sent = 0

        base = VaccinationRecord.objects.select_related('dog', 'dog__owner').prefetch_related(
            'dog__additional_owners'
        )

        newly_expired = list(base.filter(expiry_date__lt=today, expired_notice_sent=False))
        for record in newly_expired:
            # Mark sent before dispatching so a crash mid-send can't re-notify on
            # the next run — prefer at-most-once for reminders (B34).
            record.expired_notice_sent = True
            record.reminder_7_sent = True
            record.reminder_30_sent = True
            record.save(update_fields=['expired_notice_sent', 'reminder_7_sent', 'reminder_30_sent'])
            self._notify_owners(
                record,
                'Vaccination expired',
                f"{record.dog.name}'s {record.name} vaccination expired on "
                f"{record.expiry_date.strftime('%d %b %Y')}. Please update it and let us know.",
            )
            sent += 1

        week_window = base.filter(
            expiry_date__gte=today,
            expiry_date__lte=today + timedelta(days=7),
            reminder_7_sent=False,
        )
        for record in week_window:
            days_left = (record.expiry_date - today).days
            when = 'today' if days_left == 0 else f"in {days_left} day{'s' if days_left != 1 else ''}"
            record.reminder_7_sent = True
            record.reminder_30_sent = True
            record.save(update_fields=['reminder_7_sent', 'reminder_30_sent'])
            self._notify_owners(
                record,
                'Vaccination expiring soon',
                f"{record.dog.name}'s {record.name} vaccination expires {when} "
                f"({record.expiry_date.strftime('%d %b %Y')}).",
            )
            sent += 1

        month_window = base.filter(
            expiry_date__gt=today + timedelta(days=7),
            expiry_date__lte=today + timedelta(days=VaccinationRecord.EXPIRING_SOON_DAYS),
            reminder_30_sent=False,
        )
        for record in month_window:
            record.reminder_30_sent = True
            record.save(update_fields=['reminder_30_sent'])
            self._notify_owners(
                record,
                'Vaccination due for renewal',
                f"{record.dog.name}'s {record.name} vaccination expires on "
                f"{record.expiry_date.strftime('%d %b %Y')}. Time to book a booster!",
            )
            sent += 1

        if newly_expired:
            staff = User.objects.filter(is_staff=True, profile__can_manage_requests=True)
            names = ', '.join(f'{r.dog.name} ({r.name})' for r in newly_expired[:10])
            extra = '' if len(newly_expired) <= 10 else f' and {len(newly_expired) - 10} more'
            for user in staff:
                try:
                    send_push_notification(
                        user,
                        'Vaccinations expired',
                        f'Expired vaccinations need chasing: {names}{extra}.',
                        {'type': 'vaccination_staff'},
                    )
                except Exception as exc:
                    self.stderr.write(f'Failed to notify staff {user}: {exc}')

        self.stdout.write(f'Sent {sent} vaccination reminder(s).')
        # Heartbeat on success so a monitor alerts if this cron stops running (I7).
        ping_heartbeat('vaccination-reminders')
