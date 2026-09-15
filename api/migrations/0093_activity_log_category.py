from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0092_dog_change_log'),
    ]

    operations = [
        migrations.AddField(
            model_name='dogchangelog',
            name='category',
            field=models.CharField(choices=[('DOG', 'Dogs'), ('COMMS', 'Client communications'), ('CLIENTS', 'Client accounts'), ('BOOKINGS', 'Booking requests'), ('SCHEDULE', 'Daycare schedule'), ('FLEET', 'Fleet'), ('INCIDENT', 'Incidents'), ('DEFECT', 'Site defects'), ('STAFF', 'Staff'), ('COMPLIANCE', 'Safety & compliance'), ('BILLING', 'Billing'), ('SETTINGS', 'Settings')], db_index=True, default='DOG', max_length=20),
        ),
        migrations.AlterField(
            model_name='dogchangelog',
            name='dog_name',
            field=models.CharField(help_text="The entry's subject: the dog, or what a non-dog entry is about.", max_length=150),
        ),
        migrations.AlterField(
            model_name='dogchangelog',
            name='action',
            field=models.CharField(choices=[('CREATED', 'Added'), ('UPDATED', 'Updated'), ('DELETED', 'Deleted'), ('OWNER_CHANGED', 'Owner changed'), ('VACCINATION', 'Vaccination'), ('PHOTO', 'Gallery'), ('NOTE', 'Note'), ('MESSAGE', 'Message'), ('APPROVED', 'Approved'), ('DENIED', 'Denied'), ('STATUS', 'Status changed'), ('COMMENT', 'Comment'), ('ASSIGNED', 'Assignment'), ('COMPLETED', 'Check completed')], max_length=20),
        ),
        migrations.AlterField(
            model_name='dogchangelog',
            name='source',
            field=models.CharField(choices=[('APP', 'App'), ('OWNER_REQUEST', 'Approved owner request'), ('BOOKING_FORM', 'Booking form'), ('WEBSITE', 'Website'), ('ADMIN', 'Admin site'), ('SYSTEM', 'System')], default='APP', max_length=20),
        ),
    ]
