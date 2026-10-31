from django.core.management.base import BaseCommand

from api.models import Dog
from api.scheduling import effective_change_actions, release_dropped_weekdays


class Command(BaseCommand):
    help = (
        "Take dogs off future regular days on a weekday they no longer come "
        "on. Until the schedule edit did this itself, changing a dog's "
        "regular days left the days the dashboard had already booked in place, "
        "so the profile said Monday while Friday was still on the board (and "
        "would have been invoiced). Same rules as the edit: only regular days "
        "(never an extra day), strictly future, not started, not boarding, not "
        "an approved extra day. Lists first; nothing is deleted without --apply."
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

        dogs = Dog.objects.order_by('name')
        if options['dog'] is not None:
            dogs = dogs.filter(pk=options['dog'])

        today = timezone.localdate()
        total = 0
        for dog in dogs:
            if dog.schedule_type == 'ad_hoc':
                stale_weekdays = set(range(1, 8))
            else:
                stale_weekdays = set(range(1, 8)) - {int(d) for d in (dog.daycare_days or [])}
            if not stale_weekdays:
                continue
            if not options['apply']:
                rows = list(DailyDogAssignment.objects.filter(
                    dog=dog, date__gt=today, date__iso_week_day__in=stale_weekdays,
                    booking=DailyDogAssignment.BOOKING_REGULAR,
                    from_boarding=False, status__in=('ASSIGNED', 'UNASSIGNED'),
                ).select_related('staff_member').order_by('date'))
                if not rows:
                    continue
                adds_by_date, _ = effective_change_actions(
                    rows[0].date, rows[-1].date, dog_ids=[dog.id])
                for row in rows:
                    if dog.id in adds_by_date.get(row.date, set()):
                        continue
                    total += 1
                    who = row.staff_member.first_name or row.staff_member.username if row.staff_member else 'nobody'
                    self.stdout.write(
                        f"[dry-run] {dog.name} (#{dog.id}, regular days "
                        f"{sorted(int(d) for d in dog.daycare_days or [])}): "
                        f"{row.date:%a %d/%m/%Y} {row.status} with {who}"
                    )
                continue
            for day in release_dropped_weekdays(dog, stale_weekdays):
                total += 1
                self.stdout.write(f"Released {dog.name} (#{dog.id}) from {day:%a %d/%m/%Y}")

        if options['apply']:
            self.stdout.write(self.style.SUCCESS(f"Released {total} day(s)."))
        else:
            self.stdout.write(f"[dry-run] {total} day(s) to release. Run with --apply to release them.")
