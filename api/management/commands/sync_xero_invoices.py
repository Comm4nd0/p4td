"""Pull invoice status back from Xero.

Designed to run every 30 minutes from cron. Drafts raised in Xero that have
been approved there become SENT here (deleted there: VOID); open
(SENT/PART_PAID) invoices have their Xero payments imported into the local
ledger, and owners get a receipt push when their invoice becomes fully paid.
Instant no-op when Xero is not connected.
"""
from django.core.management.base import BaseCommand

from api import billing
from api.cron_heartbeat import ping_heartbeat


class Command(BaseCommand):
    help = 'Sync open invoice payment status from Xero (run every 30 minutes).'

    def handle(self, *args, **options):
        counts = billing.sync_invoices_from_xero()
        self.stdout.write(
            f"Checked {counts['checked']} invoice(s): {counts['approved']} approved in Xero, "
            f"{counts['voided']} deleted in Xero, imported {counts['payments_imported']} payment(s), "
            f"{counts['paid']} newly paid, {counts['errors']} error(s)."
        )
        ping_heartbeat('xero-sync')
