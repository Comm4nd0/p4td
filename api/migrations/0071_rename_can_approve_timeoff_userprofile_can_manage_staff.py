from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0070_dog_billing_mode_dog_xero_contact_id_and_more'),
    ]

    operations = [
        # Rename (not drop/add) so existing time-off approvers keep their
        # access as staff managers.
        migrations.RenameField(
            model_name='userprofile',
            old_name='can_approve_timeoff',
            new_name='can_manage_staff',
        ),
        migrations.AlterField(
            model_name='userprofile',
            name='can_manage_staff',
            field=models.BooleanField(default=False, help_text='Designates whether this user can manage staff: set working days and approve/deny time off requests.'),
        ),
    ]
