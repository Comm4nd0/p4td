"""End-of-day exception sweep for the business owner.

Runs from cron around closing time. Looks at today's roster and pushes one
summary to staff flagged ``receives_business_alerts`` (the business owner) if
anything never reached its normal end state:

- dogs a driver was meant to collect that were never marked picked up;
- dogs still out with the team — picked up but never marked returned home;
- attendance rows nobody ever claimed (UNASSIGNED, e.g. a boarding arrival
  no driver took on).

Silence means everything got home. Rows booked to the P4TD house account are
skipped: nobody works those statuses (the dog is with its boarding carer), so
they would only produce false alarms. Owner-transport legs are likewise not
the staff's to complete and are never flagged. Closed closure days are
skipped entirely.

Like the traffic-button oversight alert, delivery ignores the staff
working-day filter so the owner's day off doesn't swallow the warning.
"""
from datetime import datetime

from django.core.management.base import BaseCommand
from django.utils import timezone

from api.models import ClosureDay, DailyDogAssignment
from api.notifications import send_staff_notification
from api.cron_heartbeat import ping_heartbeat

# Keep the push body readable on a lock screen: name this many dogs per
# category, then summarise the rest.
MAX_NAMES = 8


def _name_list(dogs):
    names = [d.name for d in dogs[:MAX_NAMES]]
    extra = len(dogs) - len(names)
    if extra > 0:
        names.append(f'+{extra} more')
    return ', '.join(names)


class Command(BaseCommand):
    help = "Push an end-of-day exception summary to business-alert staff (run daily near closing)."

    def add_arguments(self, parser):
        parser.add_argument(
            '--date',
            help='Day to sweep as YYYY-MM-DD (default: today). For testing/backfill.',
        )

    def handle(self, *args, **options):
        if options['date']:
            target = datetime.strptime(options['date'], '%Y-%m-%d').date()
        else:
            target = timezone.localdate()

        closure = ClosureDay.objects.filter(date=target, closure_type='CLOSED').first()
        if closure:
            self.stdout.write(f'{target} is a closure day; nothing to sweep.')
            ping_heartbeat('end-of-day-alerts')
            return

        from api.scheduling import house_staff_account
        house = house_staff_account()

        rows = (
            DailyDogAssignment.objects.filter(date=target)
            .exclude(status__in=['REMOVED', 'DROPPED_OFF'])
            .select_related('dog')
        )

        not_picked_up = []   # driver leg existed, never marked picked up
        still_out = []       # with the team, never marked returned home
        unclaimed = []       # attending, but no driver ever claimed the row

        for row in rows:
            if house is not None and row.staff_member_id == house.id:
                continue
            if row.status == 'UNASSIGNED':
                # Only an exception if a staff leg actually needed doing.
                if row.needs_staff_pickup or row.needs_staff_dropoff:
                    unclaimed.append(row.dog)
            elif row.status == 'ASSIGNED' and row.needs_staff_pickup:
                not_picked_up.append(row.dog)
            elif row.status == 'PICKED_UP' and row.needs_staff_dropoff:
                still_out.append(row.dog)

        total = len(not_picked_up) + len(still_out) + len(unclaimed)
        if total == 0:
            self.stdout.write(f'{target}: no exceptions; nothing sent.')
            ping_heartbeat('end-of-day-alerts')
            return

        lines = []
        if still_out:
            lines.append(f'Still out with the team: {_name_list(still_out)}')
        if not_picked_up:
            lines.append(f'Never marked picked up: {_name_list(not_picked_up)}')
        if unclaimed:
            lines.append(f'Never assigned to a driver: {_name_list(unclaimed)}')

        title = f"End of day: {total} dog{'s' if total != 1 else ''} to check"
        body = '\n'.join(lines)
        send_staff_notification(
            title,
            body,
            {
                'type': 'end_of_day_alert',
                'date': target.isoformat(),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            },
            permission='receives_business_alerts',
            ignore_working_hours=True,
        )

        self.stdout.write(f'{target}: {total} exception(s) — {body!r}')
        # Heartbeat on success so a monitor alerts if this cron stops running (I7).
        ping_heartbeat('end-of-day-alerts')
