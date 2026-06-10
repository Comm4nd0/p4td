import os

from django.conf import settings
from django.core.management.base import BaseCommand
from django.utils.timezone import now as tz_now
from datetime import timedelta

from api.models import GroupMedia


class Command(BaseCommand):
    help = 'Delete old feed media (GroupMedia) and optionally remove orphaned files from group_media/ directories.'

    def add_arguments(self, parser):
        parser.add_argument(
            '--days',
            type=int,
            default=90,
            help='Delete feed items older than this many days (default: 90).',
        )
        parser.add_argument(
            '--dry-run',
            action='store_true',
            help='Preview what would be deleted without making changes.',
        )
        parser.add_argument(
            '--include-orphans',
            action='store_true',
            help='Also remove files in group_media/ that are not referenced by any DB record.',
        )

    def handle(self, *args, **options):
        days = options['days']
        dry_run = options['dry_run']
        include_orphans = options['include_orphans']
        cutoff = tz_now() - timedelta(days=days)

        prefix = '[DRY RUN] ' if dry_run else ''

        # --- Step A: prune old GroupMedia records ---
        old_items = GroupMedia.objects.filter(created_at__lt=cutoff)
        item_count = old_items.count()
        file_count = 0

        if dry_run:
            for item in old_items.iterator():
                if item.file:
                    file_count += 1
                if item.thumbnail:
                    file_count += 1
        else:
            for item in old_items.iterator():
                if item.file:
                    item.file.delete(save=False)
                    file_count += 1
                if item.thumbnail:
                    item.thumbnail.delete(save=False)
                    file_count += 1
                item.delete()

        self.stdout.write(
            f'{prefix}Pruned {item_count} feed items ({file_count} files).'
        )

        # --- Step B: orphan cleanup ---
        if include_orphans:
            orphan_count = self._clean_orphans(dry_run)
            self.stdout.write(
                f'{prefix}Removed {orphan_count} orphaned files.'
            )

    def _clean_orphans(self, dry_run):
        media_root = str(settings.MEDIA_ROOT)

        # Collect all file paths referenced by GroupMedia records.
        # FileField names use forward slashes regardless of OS; normalize
        # both sides of the comparison so referenced files are recognised
        # on Windows too.
        referenced = set()
        for item in GroupMedia.objects.all().iterator():
            if item.file:
                referenced.add(item.file.name.replace('\\', '/'))
            if item.thumbnail:
                referenced.add(item.thumbnail.name.replace('\\', '/'))

        orphan_count = 0
        dirs_to_scan = ['group_media', 'group_media/thumbnails']

        for rel_dir in dirs_to_scan:
            abs_dir = os.path.normpath(os.path.join(media_root, rel_dir))
            if not os.path.isdir(abs_dir):
                continue
            for filename in os.listdir(abs_dir):
                filepath = os.path.join(abs_dir, filename)
                if not os.path.isfile(filepath):
                    continue
                rel_path = f'{rel_dir}/{filename}'
                if rel_path not in referenced:
                    if not dry_run:
                        os.remove(filepath)
                    orphan_count += 1

        return orphan_count
