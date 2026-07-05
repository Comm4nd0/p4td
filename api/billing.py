"""Monthly customer billing.

Invoices are generated in arrears from actual attendance: every
``DailyDogAssignment`` row in the period whose status is not ``REMOVED``
counts as an attended day (``UNASSIGNED`` means the dog attended but had no
staff member — see the model comment). One invoice per customer per month,
one line per dog, at ``Dog.daily_rate`` falling back to the website's
``ServicePricing.day_care_price``.

Approved boarding stays bill separately at a per-night rate
(``Dog.boarding_rate`` falling back to ``ServicePricing.boarding_price_per_night``):
a billable night is a stay date before the checkout day, clamped to the
billing month. Boarding is deliberately billed IN ADDITION to any daycare
assignment on the same date (business decision: a boarded dog joining
daycare is a paid extra).

Xero is strictly best-effort: a failed push never blocks the local billing
workflow — the error is stored on the invoice and can be retried via the
``push_to_xero`` endpoint action.
"""
import calendar as _calendar
import logging
from datetime import date as date_cls, timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import Sum
from django.utils import timezone

from . import xero
from .models import BoardingRequest, DailyDogAssignment, Invoice, InvoiceLine, PaymentRecord, XeroConnection
from .notifications import send_push_notification, send_staff_notification

logger = logging.getLogger(__name__)

# Days an owner has to pay after an invoice is sent.
PAYMENT_TERMS_DAYS = 14

# Xero caps the length of the IDs= filter; batch open invoices when syncing.
XERO_FETCH_CHUNK = 40


def _customer_rate(customer, field):
    """A billed customer's per-client rate override, or None."""
    if customer is None:
        return None
    return getattr(getattr(customer, 'profile', None), field, None)


def get_day_rate(dog, customer=None):
    """The per-day daycare rate: dog override, else the billed customer's
    per-client rate (their discount), else the standard price."""
    if dog.daily_rate is not None:
        return dog.daily_rate
    client_rate = _customer_rate(customer, 'daycare_rate')
    if client_rate is not None:
        return client_rate
    # Lazy import: website is a separate app and this keeps api importable
    # without it in edge contexts (and avoids app-loading order issues).
    from website.models import ServicePricing
    return ServicePricing.load().day_care_price


def get_boarding_rate(dog, customer=None):
    """The per-night boarding rate: dog override, else the billed customer's
    per-client rate, else the standard boarding price (which is 0 until the
    business sets it — visible on drafts)."""
    if dog.boarding_rate is not None:
        return dog.boarding_rate
    client_rate = _customer_rate(customer, 'boarding_rate')
    if client_rate is not None:
        return client_rate
    from website.models import ServicePricing
    return ServicePricing.load().boarding_price_per_night


def _boarded_dog_days(year, month):
    """(dog_id, date) pairs covered by an approved boarding stay this month,
    arrival through checkout inclusive. The boarding charge covers the whole
    stay, so daycare attendance on these days is not billed separately."""
    month_start = date_cls(year, month, 1)
    month_end = date_cls(year, month, _calendar.monthrange(year, month)[1])
    covered = set()
    requests = (
        BoardingRequest.objects
        .filter(status='APPROVED', start_date__lte=month_end, end_date__gte=month_start)
        .prefetch_related('dogs')
    )
    for request in requests:
        first = max(request.start_date, month_start)
        last = min(request.end_date, month_end)
        for dog in request.dogs.all():
            for offset in range((last - first).days + 1):
                covered.add((dog.id, first + timedelta(days=offset)))
    return covered


def attendance_for_month(year, month):
    """Billable attended days per owner per dog for a calendar month.

    Returns ``{owner: {dog: [(date, owner_transport), ...]}}`` where
    ``owner_transport`` marks days the owner handled both transport legs
    (drop-off and pick-up) — those days qualify for the owner-transport
    discount. Days inside an approved boarding stay are excluded (the
    boarding charge covers them), as are dogs without an owner — there is
    nobody to bill.
    """
    boarded = _boarded_dog_days(year, month)
    assignments = (
        DailyDogAssignment.objects
        .filter(date__year=year, date__month=month)
        .exclude(status='REMOVED')
        .select_related('dog__owner')
        .order_by('date')
    )
    by_owner = {}
    for assignment in assignments:
        owner = assignment.dog.owner
        if owner is None:
            continue
        if (assignment.dog_id, assignment.date) in boarded:
            continue
        owner_transport = assignment.effective_owner_brings and assignment.effective_owner_collects
        by_owner.setdefault(owner, {}).setdefault(assignment.dog, []).append(
            (assignment.date, owner_transport))
    return by_owner


def boarding_nights_for_month(year, month):
    """Billable boarding nights per booking owner per dog for a calendar month.

    Returns ``{owner: {dog: [night dates]}}``. A billable night is a stay date
    strictly before the checkout day (Fri→Sun = 2 nights), clamped to the
    month so a stay spanning months bills each month's nights separately.
    Billed to the booking's owner (who requested the stay), one entry per dog
    on the request.
    """
    month_start = date_cls(year, month, 1)
    month_end = date_cls(year, month, _calendar.monthrange(year, month)[1])
    requests = (
        BoardingRequest.objects
        .filter(status='APPROVED', start_date__lte=month_end, end_date__gte=month_start)
        .select_related('owner')
        .prefetch_related('dogs')
    )
    by_owner = {}
    for request in requests:
        first_night = max(request.start_date, month_start)
        # Last billable night is the day before checkout, clamped to the month.
        last_night = min(request.end_date - timedelta(days=1), month_end)
        if first_night > last_night:
            continue
        nights = [
            first_night + timedelta(days=offset)
            for offset in range((last_night - first_night).days + 1)
        ]
        for dog in request.dogs.all():
            by_owner.setdefault(request.owner, {}).setdefault(dog, []).extend(nights)
    return by_owner


def generate_invoices_for_month(year, month, created_by=None, customer=None):
    """Create DRAFT invoices for every customer with daycare attendance or
    boarding nights in the period (or just one customer when ``customer``
    is given).

    Idempotent: customers who already have a non-VOID invoice for the period
    are skipped, as are customers with nothing to bill. Returns
    ``(created_invoices, skipped_count)``.
    """
    daycare_by_owner = attendance_for_month(year, month)
    boarding_by_owner = boarding_nights_for_month(year, month)

    # Merge on user id — the two maps carry separate User instances.
    customers = {}
    for owner, dogs in daycare_by_owner.items():
        customers.setdefault(owner.id, {'owner': owner, 'daycare': {}, 'boarding': {}})['daycare'] = dogs
    for owner, dogs in boarding_by_owner.items():
        customers.setdefault(owner.id, {'owner': owner, 'daycare': {}, 'boarding': {}})['boarding'] = dogs

    if customer is not None:
        entry = customers.get(customer.id)
        customers = {customer.id: entry} if entry else {}

    already_billed = set(
        Invoice.objects
        .filter(period_year=year, period_month=month)
        .exclude(status='VOID')
        .values_list('customer_id', flat=True)
    )

    created = []
    skipped = 0
    for entry in customers.values():
        if entry['owner'].id in already_billed:
            skipped += 1
            continue
        with transaction.atomic():
            invoice = Invoice.objects.create(
                customer=entry['owner'],
                period_year=year,
                period_month=month,
                status='DRAFT',
                created_by=created_by,
            )
            total = _build_lines(invoice, entry['daycare'])
            total += _build_boarding_lines(invoice, entry['boarding'])
            invoice.total = total
            invoice.save(update_fields=['total', 'updated_at'])
        created.append(invoice)
    return created, skipped


def _build_lines(invoice, dogs):
    """Create the daycare InvoiceLines for a dog map of (date, owner_transport)
    day tuples; returns the lines' total.

    Days where the owner handled both transport legs bill at the day rate
    minus the configurable owner-transport discount (as their own line, so
    the saving is visible on the invoice); other days bill at the full rate.
    """
    from website.models import ServicePricing

    discount = ServicePricing.load().owner_transport_discount
    total = Decimal('0.00')
    for dog, days in sorted(dogs.items(), key=lambda item: item[0].name.lower()):
        rate = get_day_rate(dog, customer=invoice.customer)
        split_discount = discount > 0
        standard = [d for d, owner_transport in days if not (owner_transport and split_discount)]
        discounted = [d for d, owner_transport in days if owner_transport and split_discount]
        if standard:
            line_total = rate * len(standard)
            InvoiceLine.objects.create(
                invoice=invoice,
                dog=dog,
                description=f"Daycare — {dog.name} ({len(standard)} day{'s' if len(standard) != 1 else ''} @ £{rate})",
                quantity=len(standard),
                unit_price=rate,
                line_total=line_total,
                attendance_dates=[d.isoformat() for d in standard],
            )
            total += line_total
        if discounted:
            discounted_rate = max(rate - discount, Decimal('0.00'))
            line_total = discounted_rate * len(discounted)
            InvoiceLine.objects.create(
                invoice=invoice,
                dog=dog,
                description=(
                    f"Daycare — {dog.name} ({len(discounted)} day{'s' if len(discounted) != 1 else ''} "
                    f"@ £{discounted_rate}, owner drop-off & pick-up)"
                ),
                quantity=len(discounted),
                unit_price=discounted_rate,
                line_total=line_total,
                attendance_dates=[d.isoformat() for d in discounted],
            )
            total += line_total
    return total


def _build_boarding_lines(invoice, dogs):
    """Create one boarding InvoiceLine per dog; returns the lines' total."""
    total = Decimal('0.00')
    for dog, nights in sorted(dogs.items(), key=lambda item: item[0].name.lower()):
        rate = get_boarding_rate(dog, customer=invoice.customer)
        line_total = rate * len(nights)
        InvoiceLine.objects.create(
            invoice=invoice,
            dog=dog,
            description=f"Boarding — {dog.name} ({len(nights)} night{'s' if len(nights) != 1 else ''} @ £{rate})",
            quantity=len(nights),
            unit_price=rate,
            line_total=line_total,
            attendance_dates=[d.isoformat() for d in nights],
        )
        total += line_total
    return total


def _adjustments_total(invoice):
    return invoice.lines.filter(is_adjustment=True).aggregate(total=Sum('line_total'))['total'] or Decimal('0.00')


def regenerate_draft(invoice):
    """Rebuild a DRAFT invoice's attendance/boarding lines from current data.

    Staff-entered adjustment lines are preserved — regeneration corrects the
    attendance-derived lines, it doesn't undo manual amendments.
    """
    if invoice.status != 'DRAFT':
        raise ValueError('Only draft invoices can be regenerated.')
    daycare = attendance_for_month(invoice.period_year, invoice.period_month).get(invoice.customer, {})
    boarding = {}
    for owner, dogs in boarding_nights_for_month(invoice.period_year, invoice.period_month).items():
        if owner.id == invoice.customer_id:
            boarding = dogs
            break
    with transaction.atomic():
        invoice.lines.filter(is_adjustment=False).delete()
        invoice.total = (
            _build_lines(invoice, daycare)
            + _build_boarding_lines(invoice, boarding)
            + _adjustments_total(invoice)
        )
        invoice.save(update_fields=['total', 'updated_at'])
    return invoice


def add_adjustment(invoice, description, amount):
    """Add a one-off charge (positive) or discount (negative) to a draft.

    Rejects amounts that would take the invoice total below zero — a bigger
    write-off than the bill should be handled as a credit in Xero instead.
    """
    if invoice.status != 'DRAFT':
        raise ValueError('Adjustments can only be added to draft invoices.')
    description = (description or '').strip()
    if not description:
        raise ValueError('Describe the adjustment (e.g. "Damaged lead" or "Loyalty discount").')
    amount = Decimal(str(amount))
    if amount == 0 or abs(amount) > Decimal('9999.99'):
        raise ValueError('Enter a non-zero amount up to £9999.99.')
    if invoice.total + amount < 0:
        raise ValueError('This adjustment would make the invoice total negative.')
    line = InvoiceLine.objects.create(
        invoice=invoice,
        description=description,
        quantity=1,
        unit_price=amount,
        line_total=amount,
        is_adjustment=True,
    )
    invoice.total += amount
    invoice.save(update_fields=['total', 'updated_at'])
    return line


def remove_adjustment(invoice, line_id):
    """Remove a staff-entered adjustment line from a draft. Attendance-derived
    lines can't be deleted — amend the underlying data and regenerate."""
    if invoice.status != 'DRAFT':
        raise ValueError('Adjustments can only be removed from draft invoices.')
    try:
        line = invoice.lines.get(pk=line_id, is_adjustment=True)
    except InvoiceLine.DoesNotExist:
        raise ValueError('No such adjustment line on this invoice.')
    invoice.total -= line.line_total
    line.delete()
    invoice.save(update_fields=['total', 'updated_at'])
    return invoice


def send_invoice(invoice, user=None):
    """Send a DRAFT invoice: mark it SENT, push to Xero (best-effort) and
    notify the owner."""
    if invoice.status != 'DRAFT':
        raise ValueError('Only draft invoices can be sent.')
    invoice.status = 'SENT'
    invoice.sent_at = timezone.now()
    invoice.due_date = timezone.now().date() + timezone.timedelta(days=PAYMENT_TERMS_DAYS)
    invoice.save(update_fields=['status', 'sent_at', 'due_date', 'updated_at'])

    # Outside the transaction: Xero I/O must never roll back the send.
    push_invoice_to_xero(invoice)

    send_push_notification(
        invoice.customer,
        'New invoice',
        f'Your daycare invoice for {invoice.period_label} is ready: £{invoice.total}.',
        data={'type': 'invoice', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
    )
    return invoice


def push_invoice_to_xero(invoice):
    """Create the invoice in Xero and store the ids + online payment URL.

    Best-effort: returns True on success, False when Xero is not connected or
    the push failed (error stored on ``xero_sync_error``). Never raises.
    """
    if not XeroConnection.load().is_connected:
        return False
    if invoice.xero_invoice_id:
        # Already pushed — just try to backfill the online URL if missing.
        if not invoice.xero_online_url:
            try:
                invoice.xero_online_url = xero.get_online_invoice_url(invoice.xero_invoice_id)
                invoice.save(update_fields=['xero_online_url', 'updated_at'])
            except xero.XeroError as exc:
                logger.warning('Could not fetch Xero online invoice URL: %s', exc)
        return True
    try:
        contact_id = xero.find_or_create_contact(invoice.customer)
        xero_id, xero_number = xero.create_invoice(invoice, contact_id)
        invoice.xero_invoice_id = xero_id
        invoice.xero_invoice_number = xero_number
        invoice.xero_sync_error = ''
        try:
            invoice.xero_online_url = xero.get_online_invoice_url(xero_id)
        except xero.XeroError as exc:
            logger.warning('Could not fetch Xero online invoice URL: %s', exc)
        invoice.save(update_fields=['xero_invoice_id', 'xero_invoice_number', 'xero_online_url', 'xero_sync_error', 'updated_at'])
        return True
    except xero.XeroError as exc:
        logger.error('Failed to push invoice #%s to Xero: %s', invoice.id, exc)
        invoice.xero_sync_error = str(exc)
        invoice.save(update_fields=['xero_sync_error', 'updated_at'])
        return False


def refresh_payment_state(invoice):
    """Recompute ``amount_paid`` and the paid/part-paid status from the
    payments ledger. DRAFT and VOID invoices are left alone."""
    paid = invoice.payments.aggregate(total=Sum('amount'))['total'] or Decimal('0.00')
    invoice.amount_paid = paid
    update_fields = ['amount_paid', 'updated_at']
    if invoice.status not in ('DRAFT', 'VOID'):
        if paid >= invoice.total and invoice.total > 0:
            if invoice.status != 'PAID':
                invoice.paid_at = timezone.now()
                update_fields.append('paid_at')
            invoice.status = 'PAID'
        elif paid > 0:
            invoice.status = 'PART_PAID'
        else:
            invoice.status = 'SENT'
        update_fields.append('status')
    invoice.save(update_fields=update_fields)
    return invoice


def record_manual_payment(invoice, amount, method, payment_date=None, recorded_by=None, notes=''):
    """Record a staff-entered payment (cash/transfer) against an invoice.

    Mirrors the payment into Xero (best-effort) when the invoice is pushed and
    ``XERO_PAYMENT_ACCOUNT_CODE`` is configured, so Xero doesn't keep showing
    the invoice as unpaid; the returned PaymentID doubles as the sync dedupe
    key so the payment isn't re-imported.
    """
    from django.conf import settings

    if invoice.status in ('DRAFT', 'VOID'):
        raise ValueError('Payments can only be recorded against sent invoices.')
    amount = Decimal(str(amount))
    if amount <= 0:
        raise ValueError('Payment amount must be greater than zero.')
    payment_date = payment_date or timezone.now().date()

    payment = PaymentRecord.objects.create(
        invoice=invoice,
        amount=amount,
        method=method,
        source='MANUAL',
        payment_date=payment_date,
        recorded_by=recorded_by,
        notes=notes,
    )

    account_code = getattr(settings, 'XERO_PAYMENT_ACCOUNT_CODE', '')
    if invoice.xero_invoice_id and account_code and XeroConnection.load().is_connected:
        try:
            payment.xero_payment_id = xero.create_payment(
                invoice.xero_invoice_id, amount, payment_date, account_code,
            )
            payment.save(update_fields=['xero_payment_id'])
        except xero.XeroError as exc:
            logger.error('Failed to mirror payment %s to Xero: %s', payment.id, exc)

    refresh_payment_state(invoice)

    send_push_notification(
        invoice.customer,
        'Payment received',
        f'We received £{amount} towards your {invoice.period_label} invoice. Thank you!',
        data={'type': 'invoice_payment', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
    )
    send_staff_notification(
        'Payment recorded',
        f'£{amount} ({payment.get_method_display()}) recorded on {invoice.customer.first_name or invoice.customer.username}\'s {invoice.period_label} invoice.',
        data={'type': 'invoice_payment', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
        permission='can_manage_payments',
        exclude_user=recorded_by,
    )
    return payment


def sync_invoices_from_xero():
    """Pull payment status for open invoices back from Xero.

    Imports Xero payments as PaymentRecords (deduped by ``xero_payment_id``)
    and, when Xero reports more paid than the ledger accounts for (credit
    notes, prepayments, overpayments), books the difference as a synthetic
    adjustment so the totals stay honest. Returns counts for logging.
    """
    counts = {'checked': 0, 'payments_imported': 0, 'paid': 0, 'errors': 0}
    if not XeroConnection.load().is_connected:
        return counts

    open_invoices = list(
        Invoice.objects
        .filter(status__in=('SENT', 'PART_PAID'))
        .exclude(xero_invoice_id='')
    )
    by_xero_id = {inv.xero_invoice_id: inv for inv in open_invoices}
    ids = list(by_xero_id.keys())

    now = timezone.now()
    for start in range(0, len(ids), XERO_FETCH_CHUNK):
        chunk = ids[start:start + XERO_FETCH_CHUNK]
        try:
            remote_invoices = xero.fetch_invoices(chunk)
        except xero.XeroError as exc:
            logger.error('Xero invoice sync failed: %s', exc)
            counts['errors'] += 1
            continue
        for remote in remote_invoices:
            invoice = by_xero_id.get(remote.get('InvoiceID'))
            if invoice is None:
                continue
            counts['checked'] += 1
            was_paid = invoice.status == 'PAID'
            counts['payments_imported'] += _import_remote_payments(invoice, remote)
            refresh_payment_state(invoice)
            invoice.xero_last_synced_at = now
            invoice.save(update_fields=['xero_last_synced_at', 'updated_at'])
            if invoice.status == 'PAID' and not was_paid:
                counts['paid'] += 1
                _notify_invoice_paid(invoice)
    return counts


def _import_remote_payments(invoice, remote):
    """Import unseen payments from a Xero invoice dict; returns count added."""
    imported = 0
    seen = set(invoice.payments.exclude(xero_payment_id='').values_list('xero_payment_id', flat=True))
    for remote_payment in remote.get('Payments') or []:
        payment_id = remote_payment.get('PaymentID', '')
        if not payment_id or payment_id in seen:
            continue
        PaymentRecord.objects.create(
            invoice=invoice,
            amount=Decimal(str(remote_payment.get('Amount', 0))),
            method='XERO_ONLINE',
            source='XERO',
            payment_date=_parse_xero_date(remote_payment.get('Date')) or timezone.now().date(),
            xero_payment_id=payment_id,
        )
        imported += 1

    # Credits/prepayments/overpayments don't appear in Payments[]; if Xero says
    # more has been settled than our ledger holds, book the difference.
    remote_paid = Decimal(str(remote.get('AmountPaid', 0) or 0)) + Decimal(str(remote.get('AmountCredited', 0) or 0))
    local_paid = invoice.payments.aggregate(total=Sum('amount'))['total'] or Decimal('0.00')
    if remote_paid > local_paid:
        PaymentRecord.objects.create(
            invoice=invoice,
            amount=remote_paid - local_paid,
            method='OTHER',
            source='XERO',
            payment_date=timezone.now().date(),
            notes='Xero balance adjustment (credit/prepayment).',
        )
        imported += 1
    return imported


def _parse_xero_date(value):
    """Xero JSON dates come as ``/Date(1748563200000+0000)/`` or ISO strings."""
    if not value:
        return None
    import re
    from datetime import datetime, date, timezone as dt_timezone
    match = re.search(r'/Date\((\d+)', str(value))
    if match:
        return datetime.fromtimestamp(int(match.group(1)) / 1000, tz=dt_timezone.utc).date()
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _notify_invoice_paid(invoice):
    send_push_notification(
        invoice.customer,
        'Payment received',
        f'Thank you — your {invoice.period_label} invoice is paid in full.',
        data={'type': 'invoice_payment', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
    )
    send_staff_notification(
        'Invoice paid',
        f'{invoice.customer.first_name or invoice.customer.username}\'s {invoice.period_label} invoice (£{invoice.total}) is now paid.',
        data={'type': 'invoice_payment', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
        permission='can_manage_payments',
    )
