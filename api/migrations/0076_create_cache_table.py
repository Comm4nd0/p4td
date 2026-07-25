"""Create the table backing the shared DatabaseCache.

settings.CACHES now uses django.core.cache.backends.db.DatabaseCache, because
the previous default (LocMemCache) is per-process: with 2 gunicorn workers a
price change was visible to only one of them, and every anonymous throttle
counter was effectively doubled.

DatabaseCache raises as soon as anything touches the cache if its table is
missing, and the cache is touched on nearly every request (throttling, the
ServicePricing/SiteSettings singletons). Creating it here rather than leaving
`manage.py createcachetable` as a manual deploy step means `migrate` — which
already runs on every container start — sets it up in dev, CI and production
alike, and a fresh server rebuild cannot miss it.
"""
from django.core.management import call_command
from django.db import migrations


def create_cache_table(apps, schema_editor):
    # createcachetable is idempotent: it skips tables that already exist.
    call_command('createcachetable', database=schema_editor.connection.alias, verbosity=0)


def drop_cache_table(apps, schema_editor):
    table = 'django_cache'
    with schema_editor.connection.cursor() as cursor:
        cursor.execute(f'DROP TABLE IF EXISTS {schema_editor.connection.ops.quote_name(table)}')


class Migration(migrations.Migration):

    dependencies = [
        ('api', '0075_alter_dailydogassignment_staff_member'),
    ]

    operations = [
        migrations.RunPython(create_cache_table, drop_cache_table),
    ]
