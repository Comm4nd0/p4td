from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0016_dailydogassignment'),
    ]

    operations = [
        migrations.AddField(
            model_name='userprofile',
            name='can_assign_dogs',
            field=models.BooleanField(default=False, help_text='Designates whether this user can assign dogs to other staff members.'),
        ),
    ]
