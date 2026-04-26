"""
Data migration: convert any AT_DAYCARE assignments to PICKED_UP (now "With Team")
and update the STATUS_CHOICES on DailyDogAssignment.
"""
from django.db import migrations, models


def convert_at_daycare_to_picked_up(apps, schema_editor):
    DailyDogAssignment = apps.get_model('api', 'DailyDogAssignment')
    updated = DailyDogAssignment.objects.filter(status='AT_DAYCARE').update(status='PICKED_UP')
    if updated:
        print(f'\n  Converted {updated} AT_DAYCARE assignment(s) to PICKED_UP.')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0039_dailydogassignment_owner_brings_and_more'),
    ]

    operations = [
        migrations.RunPython(convert_at_daycare_to_picked_up, migrations.RunPython.noop),
        migrations.AlterField(
            model_name='dailydogassignment',
            name='status',
            field=models.CharField(
                choices=[
                    ('ASSIGNED', 'Assigned'),
                    ('PICKED_UP', 'With Team'),
                    ('DROPPED_OFF', 'Dropped Off'),
                    ('REMOVED', 'Removed'),
                ],
                default='ASSIGNED',
                max_length=20,
            ),
        ),
    ]
