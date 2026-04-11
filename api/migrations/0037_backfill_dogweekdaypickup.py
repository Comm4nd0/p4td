"""Backfill DogWeekdayPickup from existing DailyDogAssignment history.

For every recurring dog, for every weekday it already has assignments on,
take the staff member from the most recent same-weekday assignment and
create a persistent roster entry. Skips ad-hoc dogs and skips weekdays
that are no longer part of the dog's current daycare_days.
"""

from django.db import migrations


def backfill(apps, schema_editor):
    Dog = apps.get_model('api', 'Dog')
    DailyDogAssignment = apps.get_model('api', 'DailyDogAssignment')
    DogWeekdayPickup = apps.get_model('api', 'DogWeekdayPickup')

    from django.db.models.functions import ExtractIsoWeekDay

    ad_hoc_ids = set(
        Dog.objects.filter(schedule_type='ad_hoc').values_list('id', flat=True)
    )
    daycare_days_by_dog = dict(
        Dog.objects.exclude(schedule_type='ad_hoc').values_list('id', 'daycare_days')
    )

    rows = (
        DailyDogAssignment.objects
        .annotate(weekday=ExtractIsoWeekDay('date'))
        .order_by('dog_id', 'weekday', '-date')
        .values('dog_id', 'staff_member_id', 'weekday')
    )

    seen = set()
    to_create = []
    for row in rows:
        dog_id = row['dog_id']
        weekday = row['weekday']
        if dog_id in ad_hoc_ids:
            continue
        key = (dog_id, weekday)
        if key in seen:
            continue
        current_days = daycare_days_by_dog.get(dog_id) or []
        if weekday not in current_days:
            continue
        seen.add(key)
        to_create.append(DogWeekdayPickup(
            dog_id=dog_id,
            weekday=weekday,
            staff_member_id=row['staff_member_id'],
        ))

    DogWeekdayPickup.objects.bulk_create(to_create, ignore_conflicts=True, batch_size=500)


def reverse(apps, schema_editor):
    DogWeekdayPickup = apps.get_model('api', 'DogWeekdayPickup')
    DogWeekdayPickup.objects.all().delete()


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0036_create_dogweekdaypickup'),
    ]

    operations = [
        migrations.RunPython(backfill, reverse),
    ]
