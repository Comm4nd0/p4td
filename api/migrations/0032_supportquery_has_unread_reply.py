from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0031_alter_dog_owner_on_delete'),
    ]

    operations = [
        migrations.AddField(
            model_name='supportquery',
            name='has_unread_reply',
            field=models.BooleanField(default=False, help_text='True when staff has replied and user has not yet viewed'),
        ),
    ]
