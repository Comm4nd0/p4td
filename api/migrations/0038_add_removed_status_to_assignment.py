from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0037_backfill_dogweekdaypickup'),
    ]

    operations = [
        migrations.AlterField(
            model_name='dailydogassignment',
            name='status',
            field=models.CharField(
                choices=[
                    ('ASSIGNED', 'Assigned'),
                    ('PICKED_UP', 'Picked Up'),
                    ('AT_DAYCARE', 'At Daycare'),
                    ('DROPPED_OFF', 'Dropped Off'),
                    ('REMOVED', 'Removed'),
                ],
                default='ASSIGNED',
                max_length=20,
            ),
        ),
    ]
