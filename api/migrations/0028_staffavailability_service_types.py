from django.db import migrations, models


def copy_availability_to_service_types(apps, schema_editor):
    """Copy existing is_available value to both new service-type fields."""
    StaffAvailability = apps.get_model('api', 'StaffAvailability')
    for sa in StaffAvailability.objects.all():
        sa.is_available_daycare = sa.is_available
        sa.is_available_boarding = sa.is_available
        sa.save(update_fields=['is_available_daycare', 'is_available_boarding'])


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0027_closureday_dognote_staffavailability'),
    ]

    operations = [
        migrations.AddField(
            model_name='staffavailability',
            name='is_available_daycare',
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name='staffavailability',
            name='is_available_boarding',
            field=models.BooleanField(default=True),
        ),
        migrations.RunPython(
            copy_availability_to_service_types,
            migrations.RunPython.noop,
        ),
    ]
