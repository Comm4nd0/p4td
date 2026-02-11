from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('api', '0015_userprofile_can_add_feed_media'),
    ]

    operations = [
        migrations.CreateModel(
            name='DailyDogAssignment',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('date', models.DateField()),
                ('status', models.CharField(choices=[('ASSIGNED', 'Assigned'), ('PICKED_UP', 'Picked Up'), ('AT_DAYCARE', 'At Daycare'), ('DROPPED_OFF', 'Dropped Off')], default='ASSIGNED', max_length=20)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('dog', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='daily_assignments', to='api.dog')),
                ('staff_member', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='dog_assignments', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['dog__name'],
                'unique_together': {('dog', 'date')},
            },
        ),
    ]
