from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone
from rest_framework.authtoken.models import Token


class Command(BaseCommand):
    help = (
        "Delete DRF auth tokens older than N days (default 180), forcing those "
        "users to log in again. DRF tokens never expire on their own, so a "
        "leaked or lost-device token would otherwise grant access forever; run "
        "this periodically from cron as a token-lifecycle control (B43). "
        "Password change already rotates the token (B3)."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--days', type=int, default=180,
            help='Delete tokens created more than this many days ago (default 180).',
        )
        parser.add_argument(
            '--dry-run', action='store_true',
            help='Report what would be deleted without deleting anything.',
        )

    def handle(self, *args, **options):
        days = options['days']
        cutoff = timezone.now() - timedelta(days=days)
        qs = Token.objects.filter(created__lt=cutoff)
        count = qs.count()
        if options['dry_run']:
            self.stdout.write(f"[dry-run] Would delete {count} auth token(s) older than {days} days.")
            return
        qs.delete()
        self.stdout.write(self.style.SUCCESS(
            f"Deleted {count} auth token(s) older than {days} days; affected users must re-login."
        ))
