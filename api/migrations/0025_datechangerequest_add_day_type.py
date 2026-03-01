from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0024_userprofile_notification_preferences'),
    ]

    operations = [
        migrations.AlterField(
            model_name='datechangerequest',
            name='request_type',
            field=models.CharField(
                choices=[
                    ('CANCEL', 'Cancellation'),
                    ('CHANGE', 'Date Change'),
                    ('ADD_DAY', 'Additional Day'),
                ],
                max_length=10,
            ),
        ),
        migrations.AlterField(
            model_name='datechangerequest',
            name='original_date',
            field=models.DateField(blank=True, null=True),
        ),
    ]
