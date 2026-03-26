from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('website', '0004_add_testimonial_model'),
    ]

    operations = [
        migrations.AddField(
            model_name='contactinquiry',
            name='is_replied',
            field=models.BooleanField(default=False),
        ),
    ]
