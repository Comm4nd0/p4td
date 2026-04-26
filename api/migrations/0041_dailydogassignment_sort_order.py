from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0040_remove_at_daycare_status'),
    ]

    operations = [
        migrations.AddField(
            model_name='dailydogassignment',
            name='sort_order',
            field=models.IntegerField(default=0, help_text='Custom sort order for staff pickup list. Lower numbers appear first.'),
        ),
        migrations.AlterModelOptions(
            name='dailydogassignment',
            options={'ordering': ['sort_order', 'dog__name']},
        ),
    ]
