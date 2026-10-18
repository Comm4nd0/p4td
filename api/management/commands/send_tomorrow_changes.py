"""Evening heads-up about tomorrow's changes to the routine.

Runs from cron at 18:00 (``scheduling.CHANGES_SUMMARY_HOUR``). Staff work from
routine, and the mistakes happen on the exceptions, so this tells people only
what differs from a normal day (``scheduling.day_changes``):

- **Staff.** Everyone due to work tomorrow (``working_staff_for_date``), plus
  staff with ``receives_business_alerts``, gets the whole day's changes in one
  push. The changes on their own run come first ("Yours: ..."), then the rest
  ("Also: ..."), because the whole team mixes once the dogs are in. Category
  ``schedule``. Silent when nothing differs, so it never becomes noise.
- **Owners.** Each owner (and co-owner) of a dog with an extra day or a
  cancellation tomorrow gets a reminder. Category ``bookings``.

Delivery ignores today's working-day push filter: the audience is worked out
for tomorrow, and someone off today but in tomorrow must still hear about it.
Changes made after this has run reach the team as they happen
(``notifications.notify_late_schedule_change``).
"""
from datetime import datetime, timedelta

from django.utils import timezone

from api.management.push_command import PushCommand
from api.cron_heartbeat import ping_heartbeat
from api.models import Dog
from api.notifications import (
    day_word, dog_owner_users, schedule_change_recipients, send_push_notification,
)
from api.scheduling import (
    CHANGE_CANCELLED, CHANGE_EXTRA, change_involves, change_short_text, day_changes,
)

# Keep the push readable on a lock screen.
MAX_ITEMS = 8


def _listed(changes):
    items = [change_short_text(c) for c in changes[:MAX_ITEMS]]
    extra = len(changes) - len(items)
    if extra > 0:
        items.append(f'+{extra} more')
    return ', '.join(items)


def staff_summary_text(changes, user_id, when):
    """(title, body) of one staff member's summary, their own run first."""
    mine = [c for c in changes if change_involves(c, user_id)]
    others = [c for c in changes if not change_involves(c, user_id)]
    count = len(changes)
    title = f"{when.capitalize()}: {count} change{'s' if count != 1 else ''} to the routine"
    lines = []
    if mine:
        lines.append(f'Yours: {_listed(mine)}')
    if others:
        lines.append(f"{'Also' if mine else 'Team'}: {_listed(others)}")
    return title, '\n'.join(lines)


def owner_reminder_text(dog_name, kind, when):
    """(title, body) of an owner's reminder about one dog."""
    if kind == CHANGE_EXTRA:
        return 'Extra day reminder', f"{dog_name}'s extra day at daycare is {when}."
    return 'Day off reminder', f"{dog_name} isn't booked in for daycare {when}."


class Command(PushCommand):
    help = "Push tomorrow's changes to the routine to the team, and reminders to owners (run daily at 18:00)."

    def add_arguments(self, parser):
        parser.add_argument(
            '--date',
            help='Day to summarise as YYYY-MM-DD (default: tomorrow). For testing/backfill.',
        )
        parser.add_argument(
            '--dry-run', action='store_true',
            help='Print what would be sent without pushing anything.',
        )

    def handle(self, *args, **options):
        if options['date']:
            target = datetime.strptime(options['date'], '%Y-%m-%d').date()
        else:
            target = timezone.localdate() + timedelta(days=1)
        dry_run = options['dry_run']
        when = day_word(target)

        changes = day_changes(target)
        if not changes:
            self.stdout.write(f'{target}: no changes to the routine; nothing sent.')
            ping_heartbeat('tomorrow-changes')
            return

        data = {
            'type': 'schedule_change',
            'date': target.isoformat(),
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
        }
        staff_sent = 0
        for user in schedule_change_recipients(target):
            title, body = staff_summary_text(changes, user.id, when)
            if dry_run:
                self.stdout.write(f'[staff] {user.username}: {title} — {body!r}')
            else:
                send_push_notification(
                    user, title, body, data, category='schedule', ignore_working_hours=True,
                )
            staff_sent += 1

        owner_sent = 0
        owner_changes = [c for c in changes if c['kind'] in (CHANGE_EXTRA, CHANGE_CANCELLED)]
        dogs = Dog.objects.filter(
            id__in={c['dog_id'] for c in owner_changes},
        ).select_related('owner').prefetch_related('additional_owners')
        dogs = {d.id: d for d in dogs}
        for change in owner_changes:
            dog = dogs.get(change['dog_id'])
            if dog is None:
                continue
            title, body = owner_reminder_text(dog.name, change['kind'], when)
            owner_data = {
                'type': 'schedule_reminder',
                'date': target.isoformat(),
                'dog_id': str(dog.id),
                'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            }
            for user in dog_owner_users(dog):
                if dry_run:
                    self.stdout.write(f'[owner] {user.username}: {title} — {body!r}')
                else:
                    send_push_notification(user, title, body, owner_data, category='bookings')
                owner_sent += 1

        self.stdout.write(
            f'{target}: {len(changes)} change(s); {staff_sent} staff and {owner_sent} owner push(es)'
            + (' (dry run)' if dry_run else '')
        )
        ping_heartbeat('tomorrow-changes')
