# Generated migration for daycare_days field

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0002_dog_food_instructions_dog_medical_notes_userprofile'),
    ]

    operations = [
        migrations.AddField(
            model_name='dog',
            name='daycare_days',
            field=models.JSONField(blank=True, default=list, help_text='List of day numbers (1-7) for daycare attendance'),
        ),
    ]
