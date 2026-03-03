from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0029_dayoffrequest'),
    ]

    operations = [
        migrations.AddField(
            model_name='userprofile',
            name='can_approve_timeoff',
            field=models.BooleanField(default=False, help_text='Designates whether this user can approve/deny time off requests.'),
        ),
    ]
