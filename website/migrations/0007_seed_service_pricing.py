from django.db import migrations


def seed_service_pricing(apps, schema_editor):
    ServicePricing = apps.get_model('website', 'ServicePricing')
    ServicePricing.objects.get_or_create(
        pk=1,
        defaults={
            'day_care_price': '25.00',
            'day_care_bundle_price': '110.00',
            'day_care_bundle_days': 5,
            'training_price': '40.00',
            'field_hire_price': '15.00',
        },
    )


def unseed_service_pricing(apps, schema_editor):
    ServicePricing = apps.get_model('website', 'ServicePricing')
    ServicePricing.objects.filter(pk=1).delete()


class Migration(migrations.Migration):

    dependencies = [
        ('website', '0006_servicepricing'),
    ]

    operations = [
        migrations.RunPython(seed_service_pricing, unseed_service_pricing),
    ]
