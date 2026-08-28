# Seed the safety & compliance register with the checks a UK dog daycare
# typically needs. Runs only when the register is empty, so a customised
# register is never touched; anything not applicable can be deactivated
# in-app.
from django.db import migrations

DEFAULT_CHECKS = [
    # (name, category, frequency, description)
    ('Fire alarm test', 'FIRE', 'WEEKLY',
     'Test the alarm from a different call point each week and log the point tested.'),
    ('Smoke & CO detector check', 'FIRE', 'MONTHLY',
     'Press-test every smoke and carbon monoxide detector.'),
    ('Emergency lighting test', 'FIRE', 'MONTHLY',
     'Short functional test of emergency lights; annual full-duration test by an engineer.'),
    ('Fire extinguisher visual check', 'FIRE', 'MONTHLY',
     'Check gauges, pins, seals and access; note any damage.'),
    ('Fire extinguisher service', 'FIRE', 'ANNUAL',
     'Annual service by a competent engineer.'),
    ('Fire drill / evacuation practice', 'FIRE', 'SIX_MONTHLY',
     'Practice evacuating people AND dogs; note timings and problems.'),
    ('Fire risk assessment review', 'FIRE', 'ANNUAL',
     'Review and update the written fire risk assessment.'),
    ('PAT testing (portable appliances)', 'ELECTRICAL', 'ANNUAL',
     'Portable appliance testing of kettles, dryers, chargers, heaters, etc.'),
    ('Electrical installation report (EICR)', 'ELECTRICAL', 'FIVE_YEARLY',
     'Fixed-wiring inspection by a qualified electrician.'),
    ('Gas safety certificate', 'HEALTH_SAFETY', 'ANNUAL',
     'Annual gas appliance check by a Gas Safe engineer (skip if no gas on site).'),
    ('First aid kit check & restock (human)', 'HEALTH_SAFETY', 'MONTHLY',
     'Check contents against the list, replace used or expired items.'),
    ('Canine first aid kit check & restock', 'HEALTH_SAFETY', 'MONTHLY',
     'Check contents, replace used or expired items.'),
    ('Legionella / water temperature check', 'HEALTH_SAFETY', 'MONTHLY',
     'Flush little-used outlets and record hot/cold water temperatures.'),
    ('Health & safety risk assessment review', 'HEALTH_SAFETY', 'ANNUAL',
     'Review the written H&S risk assessment, including dog-handling risks.'),
    ('Fencing, gates & secure areas walk-round', 'HEALTH_SAFETY', 'WEEKLY',
     'Walk the boundary: fence integrity, gate latches, double-gating, escape risks.'),
    ('Deep clean & disinfection', 'HYGIENE', 'MONTHLY',
     'Full deep clean of dog areas with kennel-grade disinfectant.'),
    ('Pest control inspection', 'HYGIENE', 'QUARTERLY',
     'Check bait points and signs of pests (or log the contractor visit).'),
    ('Animal welfare licence renewal', 'DOCUMENTS', 'ANNUAL',
     'Local authority licence for providing day care for dogs — renew before expiry.'),
    ('Public liability insurance renewal', 'DOCUMENTS', 'ANNUAL', ''),
    ("Employers' liability insurance renewal", 'DOCUMENTS', 'ANNUAL', ''),
    ('Vehicle insurance renewal', 'DOCUMENTS', 'ANNUAL',
     'Fleet/business motor policy (MOT and servicing are tracked in the Fleet section).'),
]


def seed(apps, schema_editor):
    ComplianceCheckType = apps.get_model('api', 'ComplianceCheckType')
    if ComplianceCheckType.objects.exists():
        return
    ComplianceCheckType.objects.bulk_create([
        ComplianceCheckType(
            name=name, category=category, frequency=frequency, description=description,
        )
        for name, category, frequency, description in DEFAULT_CHECKS
    ])


def unseed(apps, schema_editor):
    # Reversing only removes untouched seed rows (no logs), keeping history.
    ComplianceCheckType = apps.get_model('api', 'ComplianceCheckType')
    names = [c[0] for c in DEFAULT_CHECKS]
    ComplianceCheckType.objects.filter(name__in=names, logs__isnull=True).delete()


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0082_userprofile_can_manage_compliance_and_more'),
    ]

    operations = [
        migrations.RunPython(seed, unseed),
    ]
