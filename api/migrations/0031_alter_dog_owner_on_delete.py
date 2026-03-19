import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('api', '0030_userprofile_can_approve_timeoff'),
    ]

    operations = [
        migrations.AlterField(
            model_name='dog',
            name='owner',
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name='dogs',
                to=settings.AUTH_USER_MODEL,
            ),
        ),
    ]
