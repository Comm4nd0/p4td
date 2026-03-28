from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0034_queuednotification'),
    ]

    operations = [
        migrations.AddField(
            model_name='groupmedia',
            name='tagged_dogs',
            field=models.ManyToManyField(blank=True, related_name='media_appearances', to='api.dog'),
        ),
    ]
