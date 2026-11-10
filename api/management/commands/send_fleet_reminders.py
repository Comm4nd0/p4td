"""Send push reminders for vehicle MOT, servicing and tax due dates.

Designed to run daily from cron. Each milestone (30 days out, 7 days out,
overdue) notifies staff with can_manage_vehicles exactly once — bookkeeping
flags on the vehicle make reruns no-ops. Flags are re-armed when the
corresponding due date is updated (see Vehicle.save).
"""
from datetime import timedelta

from django.contrib.auth.models import User
from django.utils import timezone

from api.management.push_command import PushCommand
from api.models import Vehicle
from api.notifications import send_push_notification
from api.cron_heartbeat import ping_heartbeat


class Command(PushCommand):
    help = 'Send vehicle MOT/service/tax due reminders to fleet managers (run daily).'
    requires_firebase = True

    def _notify_managers(self, vehicle, event, title, body):
        data = {
            'type': 'fleet_reminder',
            'vehicle_id': str(vehicle.id),
            'event': event,
        }
        managers = User.objects.filter(is_staff=True, profile__can_manage_vehicles=True)
        for user in managers:
            try:
                send_push_notification(user, title, body, data)
            except Exception as exc:
                self.stderr.write(f'Failed to notify {user}: {exc}')

    def _remind(self, vehicle, flags, event, title, body):
        """One milestone: mark, send, and un-mark if FCM took nothing.

        Marked before dispatching (prefer at-most-once) (B34). Returns 1 when
        the reminder stands, 0 when it was put back for the next run.
        """
        previous = {flag: getattr(vehicle, flag) for flag in flags}
        for flag in flags:
            setattr(vehicle, flag, True)
        vehicle.save(update_fields=flags)
        with self.dispatch() as outcome:
            self._notify_managers(vehicle, event, title, body)
        if outcome.demonstrably_failed:
            for flag, value in previous.items():
                setattr(vehicle, flag, value)
            vehicle.save(update_fields=flags)
            return 0
        return 1

    def handle(self, *args, **options):
        today = timezone.localdate()
        sent = 0

        # (label, event key, date field, 30-day flag, 7-day flag, overdue flag)
        milestones = [
            ('MOT', 'mot', 'mot_due_date',
             'mot_reminder_30_sent', 'mot_reminder_7_sent', 'mot_overdue_notice_sent'),
            ('Service', 'service', 'service_due_date',
             'service_reminder_30_sent', 'service_reminder_7_sent', 'service_overdue_notice_sent'),
            ('Tax', 'tax', 'tax_due_date',
             'tax_reminder_30_sent', 'tax_reminder_7_sent', 'tax_overdue_notice_sent'),
        ]

        for label, event, date_field, flag_30, flag_7, flag_overdue in milestones:
            overdue = Vehicle.objects.filter(
                **{f'{date_field}__lt': today, flag_overdue: False}
            )
            for vehicle in overdue:
                due = getattr(vehicle, date_field)
                sent += self._remind(
                    vehicle, [flag_overdue, flag_7, flag_30], event,
                    f'{label} overdue',
                    f"{vehicle.name} ({vehicle.registration}) {label} was due on "
                    f"{due.strftime('%d %b %Y')}.",
                )

            week_window = Vehicle.objects.filter(
                **{
                    f'{date_field}__gte': today,
                    f'{date_field}__lte': today + timedelta(days=7),
                    flag_7: False,
                }
            )
            for vehicle in week_window:
                due = getattr(vehicle, date_field)
                days_left = (due - today).days
                when = 'today' if days_left == 0 else f"in {days_left} day{'s' if days_left != 1 else ''}"
                sent += self._remind(
                    vehicle, [flag_7, flag_30], event,
                    f'{label} due soon',
                    f"{vehicle.name} ({vehicle.registration}) {label} is due {when} "
                    f"({due.strftime('%d %b %Y')}).",
                )

            month_window = Vehicle.objects.filter(
                **{
                    f'{date_field}__gt': today + timedelta(days=7),
                    f'{date_field}__lte': today + timedelta(days=Vehicle.DUE_SOON_DAYS),
                    flag_30: False,
                }
            )
            for vehicle in month_window:
                due = getattr(vehicle, date_field)
                sent += self._remind(
                    vehicle, [flag_30], event,
                    f'{label} due for renewal' if event == 'tax' else f'{label} due for booking',
                    f"{vehicle.name} ({vehicle.registration}) {label} is due on "
                    f"{due.strftime('%d %b %Y')}. "
                    + ("Time to renew it!" if event == 'tax' else "Time to book it in!"),
                )

        self.stdout.write(f'Sent {sent} fleet reminder(s).')
        self.fail_if_pushes_failed()
        # Heartbeat on success so a monitor alerts if this cron stops running (I7).
        ping_heartbeat('fleet-reminders')
