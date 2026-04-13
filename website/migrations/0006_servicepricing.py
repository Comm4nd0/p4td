from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('website', '0005_contactinquiry_is_replied'),
    ]

    operations = [
        migrations.CreateModel(
            name='ServicePricing',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('day_care_price', models.DecimalField(decimal_places=2, default=25.0, help_text='Day care price per day (e.g. 25.00).', max_digits=6)),
                ('day_care_bundle_price', models.DecimalField(decimal_places=2, default=110.0, help_text='Bundle price for multiple days (e.g. 110.00).', max_digits=6)),
                ('day_care_bundle_days', models.PositiveIntegerField(default=5, help_text='Number of days included in the bundle.')),
                ('training_price', models.DecimalField(decimal_places=2, default=40.0, help_text='One-to-one training price per session (e.g. 40.00).', max_digits=6)),
                ('field_hire_price', models.DecimalField(decimal_places=2, default=15.0, help_text='Field hire price per hour (e.g. 15.00).', max_digits=6)),
            ],
            options={
                'verbose_name': 'Service pricing',
                'verbose_name_plural': 'Service pricing',
            },
        ),
    ]
