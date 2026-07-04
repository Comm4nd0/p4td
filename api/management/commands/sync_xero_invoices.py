"""Pull invoice payment status back from Xero.

Designed to run every 30 minutes from cron. Only open (SENT/PART_PAID)
invoices that were pushed to Xero are checked; payments reconciled in Xero
are imported into the local ledger and owners get a receipt push when their
invoice becomes fully paid. Instant no-op when Xero is not connected.
"""
from django.core.management.base import BaseCommand

from api import billing
from api.cron_heartbeat import ping_heartbeat


class Command(BaseCommand):
    help = 'Sync open invoice payment status from Xero (run every 30 minutes).'

    def handle(self, *args, **options):
        counts = billing.sync_invoices_from_xero()
        self.stdout.write(
            f"Checked {counts['checked']} invoice(s): imported {counts['payments_imported']} payment(s), "
            f"{counts['paid']} newly paid, {counts['errors']} error(s)."
        )
        ping_heartbeat('xero-sync')
