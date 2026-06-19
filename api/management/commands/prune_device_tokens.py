from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from api.models import DeviceToken


class Command(BaseCommand):
    help = (
        "Delete stale push-notification device tokens that haven't been "
        "refreshed in N days (default 90). The app re-registers its token on "
        "launch, so tokens for live devices are kept; this only removes tokens "
        "for devices that have gone silent (uninstalled, replaced, etc.) (B33)."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--days', type=int, default=90,
            help='Delete tokens whose updated_at is older than this many days (default 90).',
        )
        parser.add_argument(
            '--dry-run', action='store_true',
            help='Report what would be deleted without deleting anything.',
        )

    def handle(self, *args, **options):
        days = options['days']
        cutoff = timezone.now() - timedelta(days=days)
        qs = DeviceToken.objects.filter(updated_at__lt=cutoff)
        count = qs.count()
        if options['dry_run']:
            self.stdout.write(f"[dry-run] Would delete {count} device token(s) older than {days} days.")
            return
        qs.delete()
        self.stdout.write(self.style.SUCCESS(
            f"Deleted {count} stale device token(s) older than {days} days."
        ))
