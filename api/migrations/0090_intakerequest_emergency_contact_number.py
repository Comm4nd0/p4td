from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0089_userprofile_notify_messages'),
    ]

    operations = [
        migrations.AddField(
            model_name='intakerequest',
            name='emergency_contact_number',
            field=models.CharField(blank=True, help_text="Someone to call if the owner doesn't answer; becomes each dog's emergency_contact_number on approval.", max_length=50),
        ),
        migrations.AlterField(
            model_name='intakerequest',
            name='phone_number',
            field=models.CharField(blank=True, help_text="Day-to-day number; becomes each dog's contact_number on approval.", max_length=20),
        ),
    ]
