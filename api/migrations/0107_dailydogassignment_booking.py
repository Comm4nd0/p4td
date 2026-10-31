from collections import defaultdict

from django.db import migrations, models

_WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']


def _parse_days(text):
    """daycare_days as the activity log shows it ("Mon, Fri") -> {1, 5}."""
    return {_WEEKDAYS.index(part) + 1 for part in (text or '').split(', ') if part in _WEEKDAYS}


def backfill_booking(apps, schema_editor):
    """Mark every existing day REGULAR or EXTRA.

    A day is a regular day when its weekday was one of the dog's regular days
    at the moment the row was created — what the dog's schedule said then,
    rebuilt from the daycare_days/schedule_type diffs on its activity log
    (the first diff after the row was made holds the value before it; with
    none, the dog's current schedule). Anything else, and any date an
    approved ADD_DAY/CHANGE moved the dog onto, is an extra day. So a day the
    dashboard booked from a weekday the dog has since dropped stays REGULAR,
    and release_stale_roster_days can take it off.
    """
    DailyDogAssignment = apps.get_model('api', 'DailyDogAssignment')
    DateChangeRequest = apps.get_model('api', 'DateChangeRequest')
    Dog = apps.get_model('api', 'Dog')
    DogChangeLog = apps.get_model('api', 'DogChangeLog')

    added = set(
        DateChangeRequest.objects
        .filter(status='APPROVED', request_type__in=('ADD_DAY', 'CHANGE'), new_date__isnull=False)
        .values_list('dog_id', 'new_date')
    )

    # (created_at, field, old) per dog, oldest first.
    history = defaultdict(list)
    for dog_id, created_at, changes in (
        DogChangeLog.objects.filter(category='DOG', dog__isnull=False)
        .order_by('created_at').values_list('dog_id', 'created_at', 'changes')
    ):
        for change in changes or []:
            field = change.get('field')
            if field in ('daycare_days', 'schedule_type'):
                history[dog_id].append((created_at, field, change.get('old') or ''))

    def regular_then(dog, history_rows, created_at, weekday):
        days = {int(d) for d in (dog.daycare_days or [])}
        ad_hoc = dog.schedule_type == 'ad_hoc'
        seen = set()
        for when, field, old in history_rows:
            if when <= created_at or field in seen:
                continue
            seen.add(field)
            if field == 'daycare_days':
                days = _parse_days(old)
            else:
                ad_hoc = old == 'Ad Hoc'
        return not ad_hoc and weekday in days

    for dog in Dog.objects.only('id', 'daycare_days', 'schedule_type').iterator():
        rows = list(DailyDogAssignment.objects.filter(dog_id=dog.id).only('id', 'date', 'created_at'))
        if not rows:
            continue
        for row in rows:
            if (dog.id, row.date) in added:
                row.booking = 'EXTRA'
            elif regular_then(dog, history.get(dog.id, ()), row.created_at, row.date.isoweekday()):
                row.booking = 'REGULAR'
            else:
                row.booking = 'EXTRA'
        DailyDogAssignment.objects.bulk_update(rows, ['booking'], batch_size=500)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0106_dog_alternative_addresses'),
    ]

    operations = [
        migrations.AddField(
            model_name='dailydogassignment',
            name='booking',
            field=models.CharField(
                choices=[('REGULAR', 'Regular day'), ('EXTRA', 'Extra day')],
                default='EXTRA', max_length=10,
                help_text="Regular day (from the dog's weekly schedule) or extra day (added on top of it). "
                          "Set from the dog's schedule when the row is created."),
            preserve_default=False,
        ),
        migrations.RunPython(backfill_booking, migrations.RunPython.noop),
    ]
