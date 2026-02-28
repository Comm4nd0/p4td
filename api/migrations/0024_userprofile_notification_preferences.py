from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0023_dog_schedule_type'),
    ]

    operations = [
        migrations.AddField(
            model_name='userprofile',
            name='notify_feed',
            field=models.BooleanField(default=True, help_text='Receive notifications for new feed posts and comments.'),
        ),
        migrations.AddField(
            model_name='userprofile',
            name='notify_traffic',
            field=models.BooleanField(default=True, help_text='Receive traffic delay alerts for pickups and drop-offs.'),
        ),
        migrations.AddField(
            model_name='userprofile',
            name='notify_bookings',
            field=models.BooleanField(default=True, help_text='Receive updates on date change and boarding requests.'),
        ),
        migrations.AddField(
            model_name='userprofile',
            name='notify_dog_updates',
            field=models.BooleanField(default=True, help_text='Receive updates when your dog is picked up, at daycare, or dropped off.'),
        ),
    ]
