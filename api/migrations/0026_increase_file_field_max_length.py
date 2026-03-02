from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0025_datechangerequest_add_day_type'),
    ]

    operations = [
        migrations.AlterField(
            model_name='groupmedia',
            name='file',
            field=models.FileField(max_length=150, upload_to='group_media/'),
        ),
        migrations.AlterField(
            model_name='groupmedia',
            name='thumbnail',
            field=models.ImageField(blank=True, max_length=150, null=True, upload_to='group_media/thumbnails/'),
        ),
        migrations.AlterField(
            model_name='photo',
            name='file',
            field=models.FileField(max_length=150, upload_to='dog_photos/'),
        ),
        migrations.AlterField(
            model_name='photo',
            name='thumbnail',
            field=models.ImageField(blank=True, max_length=150, null=True, upload_to='dog_photos/thumbnails/'),
        ),
    ]
