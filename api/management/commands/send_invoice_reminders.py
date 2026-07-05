"""Send payment reminders for overdue invoices.

Designed to run daily from cron. Each overdue invoice reminds its owner
exactly once — the overdue_reminder_sent flag makes reruns no-ops (marked
before dispatch, preferring at-most-once like the other reminder crons).
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from api.cron_heartbeat import ping_heartbeat
from api.models import Invoice
from api.notifications import send_push_notification


class Command(BaseCommand):
    help = 'Send overdue payment reminders to invoice owners (run daily).'

    def handle(self, *args, **options):
        today = timezone.localdate()
        overdue = Invoice.objects.filter(
            status__in=('SENT', 'PART_PAID'),
            due_date__lt=today,
            overdue_reminder_sent=False,
            # Dog-name invoices have no app user to remind — chased via Xero.
            customer__isnull=False,
        ).select_related('customer')

        sent = 0
        for invoice in overdue:
            # Mark sent before dispatching (prefer at-most-once).
            invoice.overdue_reminder_sent = True
            invoice.save(update_fields=['overdue_reminder_sent', 'updated_at'])
            balance = invoice.total - invoice.amount_paid
            send_push_notification(
                invoice.customer,
                'Payment reminder',
                f'Your daycare invoice for {invoice.period_label} (£{balance} outstanding) '
                f'was due on {invoice.due_date.strftime("%d %b %Y")}.',
                data={'type': 'invoice', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
            )
            sent += 1

        self.stdout.write(f'Sent {sent} overdue invoice reminder(s).')
        ping_heartbeat('invoice-reminders')
