"""Re-point the already-materialised days of dogs the owner drives both ways.

Until now a dog whose owner both drops off and collects was materialised as an
UNASSIGNED row, which the day's board hides — and unassigned_dogs hides the
dog too — so every week it looked as if it had never been booked in and staff
put it on the P4TD house account by hand. Materialisation now books those dogs
to P4TD directly; this converts the future rows the old code already wrote so
the first week after the deploy does not still need the manual step.
"""
from django.db import migrations


def book_to_house(apps, schema_editor):
    from django.utils import timezone

    User = apps.get_model('auth', 'User')
    DailyDogAssignment = apps.get_model('api', 'DailyDogAssignment')

    staff = User.objects.filter(is_staff=True)
    house = (
        staff.filter(username__iexact='p4td').first()
        or staff.filter(first_name__iexact='p4td').first()
    )
    if house is None:
        return
    DailyDogAssignment.objects.filter(
        status='UNASSIGNED',
        date__gte=timezone.localdate(),
        dog__owner_brings_default=True,
        dog__owner_collects_default=True,
    ).update(status='ASSIGNED', staff_member=house)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0098_certificate_reminders'),
    ]

    operations = [
        migrations.RunPython(book_to_house, migrations.RunPython.noop),
    ]
