from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0022_userprofile_profile_photo'),
    ]

    operations = [
        migrations.AddField(
            model_name='dog',
            name='schedule_type',
            field=models.CharField(
                choices=[('weekly', 'Weekly'), ('fortnightly', 'Fortnightly'), ('ad_hoc', 'Ad Hoc')],
                default='weekly',
                help_text='How often the dog attends: weekly, fortnightly, or ad hoc',
                max_length=20,
            ),
        ),
    ]
