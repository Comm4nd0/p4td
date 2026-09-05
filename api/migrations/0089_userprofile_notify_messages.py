from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0088_xero_unassigned_contact'),
    ]

    operations = [
        migrations.AddField(
            model_name='userprofile',
            name='notify_messages',
            field=models.BooleanField(default=True, help_text='Receive a push when a message thread with the daycare gets a reply (staff: when a client writes in).'),
        ),
    ]
