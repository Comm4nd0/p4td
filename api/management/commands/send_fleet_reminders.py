"""Send push reminders for vehicle MOT and servicing due dates.

Designed to run daily from cron. Each milestone (30 days out, 7 days out,
overdue) notifies staff with can_manage_vehicles exactly once — bookkeeping
flags on the vehicle make reruns no-ops. Flags are re-armed when the
corresponding due date is updated (see VehicleViewSet.perform_update).
"""
from datetime import date, timedelta

from django.contrib.auth.models import User
from django.core.management.base import BaseCommand

from api.models import Vehicle
from api.notifications import send_push_notification


class Command(BaseCommand):
    help = 'Send vehicle MOT/service due reminders to fleet managers (run daily).'

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

    def handle(self, *args, **options):
        today = date.today()
        sent = 0

        # (label, event key, date field, 30-day flag, 7-day flag, overdue flag)
        milestones = [
            ('MOT', 'mot', 'mot_due_date',
             'mot_reminder_30_sent', 'mot_reminder_7_sent', 'mot_overdue_notice_sent'),
            ('Service', 'service', 'service_due_date',
             'service_reminder_30_sent', 'service_reminder_7_sent', 'service_overdue_notice_sent'),
        ]

        for label, event, date_field, flag_30, flag_7, flag_overdue in milestones:
            overdue = Vehicle.objects.filter(
                **{f'{date_field}__lt': today, flag_overdue: False}
            )
            for vehicle in overdue:
                due = getattr(vehicle, date_field)
                self._notify_managers(
                    vehicle, event,
                    f'{label} overdue',
                    f"{vehicle.name} ({vehicle.registration}) {label} was due on "
                    f"{due.strftime('%d %b %Y')}.",
                )
                setattr(vehicle, flag_overdue, True)
                setattr(vehicle, flag_7, True)
                setattr(vehicle, flag_30, True)
                vehicle.save(update_fields=[flag_overdue, flag_7, flag_30])
                sent += 1

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
                self._notify_managers(
                    vehicle, event,
                    f'{label} due soon',
                    f"{vehicle.name} ({vehicle.registration}) {label} is due {when} "
                    f"({due.strftime('%d %b %Y')}).",
                )
                setattr(vehicle, flag_7, True)
                setattr(vehicle, flag_30, True)
                vehicle.save(update_fields=[flag_7, flag_30])
                sent += 1

            month_window = Vehicle.objects.filter(
                **{
                    f'{date_field}__gt': today + timedelta(days=7),
                    f'{date_field}__lte': today + timedelta(days=Vehicle.DUE_SOON_DAYS),
                    flag_30: False,
                }
            )
            for vehicle in month_window:
                due = getattr(vehicle, date_field)
                self._notify_managers(
                    vehicle, event,
                    f'{label} due for booking',
                    f"{vehicle.name} ({vehicle.registration}) {label} is due on "
                    f"{due.strftime('%d %b %Y')}. Time to book it in!",
                )
                setattr(vehicle, flag_30, True)
                vehicle.save(update_fields=[flag_30])
                sent += 1

        self.stdout.write(f'Sent {sent} fleet reminder(s).')
