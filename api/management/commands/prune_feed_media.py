import os
import time

from django.conf import settings
from django.core.management.base import BaseCommand
from django.db.models import Q
from django.utils.timezone import now as tz_now
from datetime import timedelta

from api.models import GroupMedia
from api.cron_heartbeat import ping_heartbeat

# How long a file must have sat on disk unreferenced before the orphan sweep
# will remove it. Django writes an upload to disk *before* the row that points
# at it is committed, so a file created while this command is running looks
# exactly like an orphan. Dog gallery photos now carry medical records that
# staff photograph, so the sweep errs firmly on the side of keeping a file for
# another week.
DEFAULT_ORPHAN_GRACE_HOURS = 24


class Command(BaseCommand):
    help = (
        'Delete old feed media (GroupMedia) and optionally remove orphaned files '
        'from group_media/ and dog_photos/ directories. Dog gallery photos '
        '(Photo rows) are never deleted by age — only their orphaned files are '
        'swept, and only once nothing in the database points at them.'
    )

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
            help='Also remove files in group_media/ and dog_photos/ that are not referenced by any DB record.',
        )
        parser.add_argument(
            '--orphan-grace-hours',
            type=int,
            default=DEFAULT_ORPHAN_GRACE_HOURS,
            help=(
                'Leave unreferenced files alone until they are this many hours '
                f'old (default: {DEFAULT_ORPHAN_GRACE_HOURS}). Guards against '
                'deleting an upload that is still being written.'
            ),
        )

    def handle(self, *args, **options):
        days = options['days']
        dry_run = options['dry_run']
        include_orphans = options['include_orphans']
        grace_hours = options['orphan_grace_hours']
        cutoff = tz_now() - timedelta(days=days)

        prefix = '[DRY RUN] ' if dry_run else ''

        # --- Step A: prune old GroupMedia records ---
        # Feed posts only. Dog gallery photos (Photo) are deliberately absent:
        # staff photograph medical records into a dog's gallery, so those stay
        # until the photo or the dog is deleted. Do not add Photo here.
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
            orphan_count = self._clean_orphans(dry_run, grace_hours)
            self.stdout.write(
                f'{prefix}Removed {orphan_count} orphaned files.'
            )

        # Ping the dead-man's-switch only on a real (non-dry-run) success (I7).
        if not dry_run:
            ping_heartbeat('prune-feed-media')

    def _clean_orphans(self, dry_run, grace_hours):
        """Remove files under the media dirs that no database row points at.

        Deleting a live dog photo here would destroy a medical record staff
        cannot re-take, so a file has to fail three separate checks before it
        goes: it is absent from the reference snapshot, it is older than the
        grace period, and a second look at the database — taken after the
        directory listing, so it cannot be stale — still finds nothing
        pointing at it.
        """
        media_root = str(settings.MEDIA_ROOT)

        # Collect all file paths referenced by GroupMedia and Photo records.
        # FileField names use forward slashes regardless of OS; normalize
        # both sides of the comparison so referenced files are recognised
        # on Windows too.
        #
        # dog_photos/ is scanned as well as group_media/: PhotoViewSet now
        # removes files on delete, but this is the backstop for rows deleted
        # before that (or via a cascade / the admin), which otherwise leave
        # images on the CX22's disk forever.
        referenced = self._referenced_names()

        cutoff = time.time() - grace_hours * 3600
        candidates = []  # (abs_path, rel_path)
        too_new = 0

        dirs_to_scan = [
            'group_media', 'group_media/thumbnails',
            'dog_photos', 'dog_photos/thumbnails',
        ]

        for rel_dir in dirs_to_scan:
            abs_dir = os.path.normpath(os.path.join(media_root, rel_dir))
            if not os.path.isdir(abs_dir):
                continue
            for filename in os.listdir(abs_dir):
                filepath = os.path.join(abs_dir, filename)
                if not os.path.isfile(filepath):
                    continue
                rel_path = f'{rel_dir}/{filename}'
                if rel_path in referenced:
                    continue
                try:
                    if os.path.getmtime(filepath) > cutoff:
                        # Written since (or during) the snapshot above — its
                        # row may not have been committed yet. Next run.
                        too_new += 1
                        continue
                except OSError:
                    continue  # vanished under us; nothing to delete
                candidates.append((filepath, rel_path))

        if too_new:
            self.stdout.write(
                f'Left {too_new} unreferenced file(s) alone: newer than the '
                f'{grace_hours}h grace period.'
            )
        if not candidates:
            return 0

        # Second look, now that the listing is done: anything uploaded while
        # we were walking the directories is in the database by now, and the
        # snapshot above predates it.
        claimed = self._referenced_names([rel for _, rel in candidates])

        orphan_count = 0
        for filepath, rel_path in candidates:
            if rel_path in claimed:
                continue
            if not dry_run:
                try:
                    os.remove(filepath)
                except OSError:
                    continue
            orphan_count += 1

        return orphan_count

    @staticmethod
    def _referenced_names(names=None):
        """Media file names the database points at.

        With ``names``, only those are looked up — a cheap re-check of a
        specific set of candidates rather than another full scan.
        """
        from api.models import Photo

        referenced = set()
        for model in (GroupMedia, Photo):
            qs = model.objects.all()
            if names is not None:
                qs = qs.filter(Q(file__in=names) | Q(thumbnail__in=names))
            for item in qs.values_list('file', 'thumbnail').iterator():
                for name in item:
                    if name:
                        referenced.add(name.replace('\\', '/'))
        return referenced
