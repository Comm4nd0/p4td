"""Generate draft monthly invoices from attendance records.

Designed to run from cron on the 1st of each month, billing the previous
calendar month in arrears. Idempotent: customers who already have a non-VOID
invoice for the period are skipped, so reruns create nothing new. Staff with
can_manage_payments get a push prompting them to review and send the drafts.
"""
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from api import billing
from api.cron_heartbeat import ping_heartbeat
from api.notifications import send_staff_notification


class Command(BaseCommand):
    help = 'Generate draft invoices for a month from attendance (default: previous month). Run on the 1st.'

    def add_arguments(self, parser):
        parser.add_argument('--year', type=int, help='Billing year (defaults to the previous calendar month).')
        parser.add_argument('--month', type=int, help='Billing month 1-12 (defaults to the previous calendar month).')

    def handle(self, *args, **options):
        year, month = options.get('year'), options.get('month')
        if (year is None) != (month is None):
            raise CommandError('Provide both --year and --month, or neither.')
        if year is None:
            today = timezone.localdate()
            year, month = (today.year - 1, 12) if today.month == 1 else (today.year, today.month - 1)
        if not 1 <= month <= 12:
            raise CommandError('Month must be 1-12.')

        created, skipped = billing.generate_invoices_for_month(year, month)
        label = created[0].period_label if created else f'{month}/{year}'
        self.stdout.write(f'Created {len(created)} draft invoice(s) for {label}; skipped {skipped} already billed.')

        if created:
            send_staff_notification(
                'Invoices ready for review',
                f'{len(created)} draft invoice(s) for {label} are ready to review and send.',
                data={'type': 'invoices_generated', 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
                permission='can_manage_payments',
            )

        ping_heartbeat('monthly-invoices')
