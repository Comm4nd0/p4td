from django.core.management.base import BaseCommand

from api.dog_changes import _WEEKDAYS
from api.models import Dog, DogChangeLog
from api.scheduling import release_dropped_weekdays


def _dropped_at(dog, weekday):
    """When ``weekday`` last stopped being one of ``dog``'s regular days, from
    the field diffs on its trail (daycare_days reads "Mon, Fri"); None when the
    trail doesn't show it."""
    name = _WEEKDAYS[weekday - 1]
    entries = (
        DogChangeLog.objects.filter(dog=dog, category='DOG')
        .order_by('-created_at').values_list('created_at', 'changes')
    )
    for created_at, changes in entries:
        for change in changes or []:
            field = change.get('field')
            old, new = change.get('old') or '', change.get('new') or ''
            if field == 'daycare_days' and name in old.split(', ') and name not in new.split(', '):
                return created_at
            if field == 'schedule_type' and new == 'Ad Hoc' and old != 'Ad Hoc':
                return created_at
    return None


class Command(BaseCommand):
    help = (
        "Take dogs off future days booked from a regular weekday they no longer "
        "come on. Until the schedule edit did this itself, changing a dog's "
        "regular days left the days the dashboard had already booked in place, "
        "so the profile said Monday while Friday was still on the board (and "
        "would have been invoiced). Same rules as the edit: strictly future, "
        "not started, not boarding, not an approved extra day, not a day staff "
        "put the dog on by hand after it stopped being a regular day. Lists first; nothing is deleted without --apply."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--apply', action='store_true',
            help='Delete the rows (default is to list them).',
        )
        parser.add_argument(
            '--dog', type=int, default=None,
            help='Only this dog id.',
        )

    def handle(self, *args, **options):
        from django.utils import timezone

        from api.models import DailyDogAssignment

        dogs = Dog.objects.exclude(schedule_type='ad_hoc').order_by('name')
        if options['dog'] is not None:
            dogs = dogs.filter(pk=options['dog'])

        today = timezone.localdate()
        total = 0
        for dog in dogs:
            stale_weekdays = set(range(1, 8)) - {int(d) for d in (dog.daycare_days or [])}
            if not stale_weekdays:
                continue
            if not options['apply']:
                rows = DailyDogAssignment.objects.filter(
                    dog=dog, date__gt=today, date__iso_week_day__in=stale_weekdays,
                    from_boarding=False, status__in=('ASSIGNED', 'UNASSIGNED'),
                ).order_by('date')
                for row in rows:
                    total += 1
                    self.stdout.write(
                        f"[dry-run] {dog.name} (#{dog.id}, regular days "
                        f"{sorted(int(d) for d in dog.daycare_days or [])}): "
                        f"{row.date:%a %d/%m/%Y} {row.status} — candidate; "
                        f"--apply keeps it if it is an approved extra day or was booked by hand"
                    )
                continue
            # Per weekday: a day staff put the dog on by hand counts only
            # once that weekday had stopped being a regular day.
            released = []
            for weekday in sorted(stale_weekdays):
                released += release_dropped_weekdays(
                    dog, {weekday}, regular_until=_dropped_at(dog, weekday))
            for day in sorted(released):
                total += 1
                self.stdout.write(f"Released {dog.name} (#{dog.id}) from {day:%a %d/%m/%Y}")

        if options['apply']:
            self.stdout.write(self.style.SUCCESS(f"Released {total} day(s)."))
        else:
            self.stdout.write(f"[dry-run] {total} candidate day(s). Run with --apply to release them.")
