from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0042_dog_profile_change_request'),
    ]

    operations = [
        migrations.DeleteModel(
            name='QueuedNotification',
        ),
    ]
