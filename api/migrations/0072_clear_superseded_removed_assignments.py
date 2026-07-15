# Data repair for the "removed from a day, then added back" bug: approving an
# ADD_DAY used to leave a stale REMOVED DailyDogAssignment in place, so the
# re-added day never showed on the roster, the owner calendar, or the
# unassigned list. Approval now deletes the marker; this migration cleans up
# future-dated rows that an approved addition had already superseded before
# the fix. Past rows are left alone — they are billing history.
from datetime import date

from django.db import migrations


def clear_superseded_removed_assignments(apps, schema_editor):
    DailyDogAssignment = apps.get_model('api', 'DailyDogAssignment')
    DateChangeRequest = apps.get_model('api', 'DateChangeRequest')

    stale_ids = []
    removed_rows = DailyDogAssignment.objects.filter(
        status='REMOVED', date__gte=date.today(),
    ).only('id', 'dog_id', 'date', 'updated_at')
    for row in removed_rows:
        superseding = DateChangeRequest.objects.filter(
            dog_id=row.dog_id,
            status='APPROVED',
            new_date=row.date,
            request_type__in=('ADD_DAY', 'CHANGE'),
        ).only('approved_at', 'created_at')
        for req in superseding:
            approved = req.approved_at or req.created_at
            if approved and approved > row.updated_at:
                stale_ids.append(row.id)
                break
    if stale_ids:
        DailyDogAssignment.objects.filter(id__in=stale_ids).delete()


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0071_rename_can_approve_timeoff_userprofile_can_manage_staff'),
    ]

    operations = [
        migrations.RunPython(
            clear_superseded_removed_assignments, migrations.RunPython.noop,
        ),
    ]
