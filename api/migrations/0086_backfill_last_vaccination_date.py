# Backfill Dog.last_vaccination_date from existing detailed vaccination
# records (latest date administered per dog), matching the ongoing sync in
# models.sync_dog_last_vaccination.
from django.db import migrations
from django.db.models import Max


def backfill(apps, schema_editor):
    Dog = apps.get_model('api', 'Dog')
    VaccinationRecord = apps.get_model('api', 'VaccinationRecord')
    latest = (
        VaccinationRecord.objects.values('dog_id')
        .annotate(latest=Max('date_administered'))
    )
    for row in latest:
        Dog.objects.filter(pk=row['dog_id']).update(last_vaccination_date=row['latest'])


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0085_dog_last_vaccination_date'),
    ]

    operations = [
        migrations.RunPython(backfill, migrations.RunPython.noop),
    ]
