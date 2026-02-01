from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0003_dog_daycare_days'),
    ]

    operations = [
        migrations.RemoveField(
            model_name='dog',
            name='breed',
        ),
        migrations.DeleteModel(
            name='Breed',
        ),
    ]
