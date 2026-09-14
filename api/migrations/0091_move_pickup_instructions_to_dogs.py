from django.db import migrations, models


def copy_profile_instructions_to_dogs(apps, schema_editor):
    """Pickup instructions were per person; they are now per dog
    (Dog.access_instructions). Carry each owner's text onto every dog they
    own that has none of its own, so nothing staff rely on disappears."""
    UserProfile = apps.get_model('api', 'UserProfile')
    Dog = apps.get_model('api', 'Dog')
    for profile in UserProfile.objects.exclude(pickup_instructions__isnull=True).exclude(pickup_instructions=''):
        text = profile.pickup_instructions.strip()
        if not text:
            continue
        for dog in Dog.objects.filter(owner_id=profile.user_id):
            if not (dog.access_instructions or '').strip():
                dog.access_instructions = text
                dog.save(update_fields=['access_instructions'])


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0090_intakerequest_emergency_contact_number'),
    ]

    operations = [
        migrations.RunPython(copy_profile_instructions_to_dogs, migrations.RunPython.noop),
        migrations.RemoveField(
            model_name='userprofile',
            name='pickup_instructions',
        ),
        migrations.AlterField(
            model_name='dog',
            name='access_instructions',
            field=models.TextField(blank=True, null=True, help_text='Pickup instructions for this dog — keys, codes, gates, where the dog waits. Per dog (two dogs at one address can differ); owners propose changes through dog-profile-changes like the address.'),
        ),
    ]
