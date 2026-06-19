from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0057_passwordresetotp_api_passwor_user_id_868393_idx'),
    ]

    operations = [
        migrations.AddField(
            model_name='dogweekdaypickup',
            name='sort_order',
            field=models.IntegerField(default=0, help_text='Remembered route position for this weekday; copied into the daily assignment on materialization.'),
        ),
        migrations.AlterModelOptions(
            name='dogweekdaypickup',
            options={'ordering': ['weekday', 'sort_order', 'dog__name']},
        ),
    ]
