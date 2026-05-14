from django.db import migrations, models


def backfill_is_spayed(apps, schema_editor):
    Dog = apps.get_model('api', 'Dog')
    Dog.objects.all().update(is_spayed=True)


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0043_delete_queuednotification'),
    ]

    operations = [
        migrations.AddField(
            model_name='dog',
            name='sex',
            field=models.CharField(
                blank=True,
                choices=[('M', 'Male'), ('F', 'Female')],
                max_length=1,
                null=True,
            ),
        ),
        migrations.AddField(
            model_name='dog',
            name='date_of_birth',
            field=models.DateField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='dog',
            name='is_spayed',
            field=models.BooleanField(
                default=False,
                help_text='Whether the dog has been spayed/neutered. Staff-only field.',
            ),
        ),
        migrations.RunPython(backfill_is_spayed, migrations.RunPython.noop),
    ]
