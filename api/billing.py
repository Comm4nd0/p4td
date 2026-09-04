"""Monthly customer billing.

Invoices are generated in arrears from actual attendance: every
``DailyDogAssignment`` row in the period whose status is not ``REMOVED``
counts as an attended day (``UNASSIGNED`` means the dog attended but had no
staff member — see the model comment). One invoice per customer per month,
one line per dog, at ``Dog.daily_rate`` (a payment manager's per-dog
override), else the customer's per-client rate, else the tier for how many
days a week the dog is *booked in* (``ServicePricing.day_care_tier``: one
day, two to four, five). The tier follows the booking, not the month's
attendance — a one-day-a-week dog that adds an extra day pays the one-day
rate for both, which the line description spells out.

Approved boarding stays bill separately at a per-night rate
(``Dog.boarding_rate`` falling back to ``ServicePricing.boarding_price_per_night``):
a billable night is a stay date before the checkout day, clamped to the
billing month. Boarding REPLACES the daycare charge for the days it covers —
``attendance_for_month`` subtracts ``_boarded_dog_days``, so a boarded dog is
never charged for both on the same date. (This paragraph previously claimed the
opposite, which is a dangerous thing to leave lying around next to a billing
engine: anyone "fixing the code to match the docs" would double-charge every
boarding customer.)

Every generated draft is also raised in Xero as a DRAFT invoice (when Xero
is connected), so the business can review, reassign the contact and approve
it inside Xero. ``sync_invoices_from_xero`` notices the approval and flips the
app's copy to SENT — adopting Xero's total and due date, since what Xero
emailed is the invoice the customer has — and learns the contact the draft was
reassigned to, pinning it to the dog so next month's draft goes straight
there. Approving from the app (``send_invoice``) authorises the same Xero
draft rather than raising a second invoice.

Xero is best-effort for *retries* — a push failure stores the error on the
invoice — but ``send_invoice`` will not mark an invoice SENT unless the push
succeeded, so an invoice is never presented to a customer as sent when Xero
never received it.
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

# The Xero contact a per-dog draft is raised against until the dog has a
# pinned contact. Xero requires a contact on every invoice, and inventing one
# per dog would litter the contact list — the business reassigns the draft to
# the real customer in Xero, and the sync pins that contact to the dog.
UNASSIGNED_CONTACT_NAME = 'Unassigned (Paws 4 Thought app)'

# Xero statuses that mean the invoice has been approved (and possibly settled).
XERO_APPROVED_STATUSES = ('AUTHORISED', 'PAID')
XERO_CANCELLED_STATUSES = ('DELETED', 'VOIDED')


class XeroSendFailed(Exception):
    """Raised by send_invoice when Xero is connected but rejected the push.

    The invoice is returned to DRAFT before this is raised, so a retry picks it
    up normally. Callers should report it per-invoice rather than aborting a
    whole batch.
    """


def _customer_rate(customer, field):
    """A billed customer's per-client rate override, or None."""
    if customer is None:
        return None
    return getattr(getattr(customer, 'profile', None), field, None)


def get_day_rate(dog, customer=None):
    """The per-day daycare rate: dog override, else the billed customer's
    per-client rate (their discount), else the tier for the dog's booked
    days a week."""
    return resolve_day_rate(dog, customer)[0]


def resolve_day_rate(dog, customer=None):
    """``(rate, note)`` where ``note`` says which rate applied — shown on the
    invoice line so an owner can see why an extra day cost the full amount."""
    if dog.daily_rate is not None:
        return dog.daily_rate, 'agreed rate'
    client_rate = _customer_rate(customer, 'daycare_rate')
    if client_rate is not None:
        return client_rate, 'agreed rate'
    # Lazy import: website is a separate app and this keeps api importable
    # without it in edge contexts (and avoids app-loading order issues).
    from website.models import ServicePricing
    return ServicePricing.load().day_care_tier(dog.regular_days_per_week)


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
    boarding charge covers them).
    """
    boarded = _boarded_dog_days(year, month)
    assignments = (
        DailyDogAssignment.objects
        .filter(date__year=year, date__month=month)
        .exclude(status='REMOVED')
        .select_related('dog__owner__profile')
        .order_by('date')
    )
    by_owner = {}
    for assignment in assignments:
        if (assignment.dog_id, assignment.date) in boarded:
            continue
        owner_transport = assignment.effective_owner_brings and assignment.effective_owner_collects
        # Ownerless dogs group under None — they get per-dog invoices in the
        # dog's name rather than being silently unbilled.
        by_owner.setdefault(assignment.dog.owner, {}).setdefault(assignment.dog, []).append(
            (assignment.date, owner_transport))
    return by_owner


def boarding_nights_for_month(year, month):
    """Billable boarding nights per DOG OWNER per dog for a calendar month.

    Returns ``{owner: {dog: [night dates]}}``. A billable night is a stay date
    strictly before the checkout day (Fri→Sun = 2 nights), clamped to the
    month so a stay spanning months bills each month's nights separately.

    Charges always follow the dog's assigned client — never whoever created
    the booking (staff often book on a client's behalf). Dogs with no client
    group under None and get per-dog invoices in the dog's name.
    """
    month_start = date_cls(year, month, 1)
    month_end = date_cls(year, month, _calendar.monthrange(year, month)[1])
    requests = (
        BoardingRequest.objects
        .filter(status='APPROVED', start_date__lte=month_end, end_date__gte=month_start)
        .prefetch_related('dogs__owner__profile')
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
            by_owner.setdefault(dog.owner, {}).setdefault(dog, []).extend(nights)
    return by_owner


def generate_invoices_for_month(year, month, created_by=None, customer=None, dog=None):
    """Create DRAFT invoices for every APP-billed customer with daycare
    attendance or boarding nights in the period (or just one customer when
    ``customer`` is given, or just one dog when ``dog`` is given).

    MANUAL-mode customers (and ownerless dogs) are left alone — the business
    still invoices them by hand in Xero each month, and generating here too
    would double-bill them. Passing ``customer`` or ``dog`` bypasses that
    check: an explicit single generation is a deliberate staff action (and the
    escape hatch for one-off app invoices during the transition).

    A ``dog`` invoice is raised in the dog's name whether or not the dog has a
    client attached: most of the client book isn't on the app yet, so the
    business raises the month per dog, then assigns the customer in Xero.

    Idempotent: a customer with a non-VOID invoice for the period is skipped,
    and a dog already on any non-VOID invoice for the period (its own, or its
    owner's) is never billed twice — a per-dog invoice raised first drops that
    dog from the owner's invoice, and vice versa. Customers/dogs with nothing
    left to bill are skipped too. Every created draft is also raised as a
    DRAFT in Xero when connected. Returns
    ``(created_invoices, skipped_count, manual_count)``.
    """
    target_dog = dog
    if customer is not None and target_dog is not None:
        raise ValueError('Generate for a customer or a dog, not both.')
    daycare_by_owner = attendance_for_month(year, month)
    boarding_by_owner = boarding_nights_for_month(year, month)

    if target_dog is not None:
        # Per-dog: lift this dog's charges out of its owner's bucket.
        daycare_by_owner = {None: {d: v for d, v in daycare_by_owner.get(target_dog.owner, {}).items() if d.id == target_dog.id}}
        boarding_by_owner = {None: {d: v for d, v in boarding_by_owner.get(target_dog.owner, {}).items() if d.id == target_dog.id}}

    # Merge on user id (the two maps carry separate User instances). Dogs with
    # no client attached bill per dog, in the dog's name, so key those by dog.
    customers = {}

    def _entry(owner, dog):
        key = ('user', owner.id) if owner is not None else ('dog', dog.id)
        return customers.setdefault(key, {
            'owner': owner,
            'dog': dog if owner is None else None,
            'daycare': {},
            'boarding': {},
        })

    for owner, dogs in daycare_by_owner.items():
        for d, days in dogs.items():
            _entry(owner, d)['daycare'][d] = days
    for owner, dogs in boarding_by_owner.items():
        for d, nights in dogs.items():
            _entry(owner, d)['boarding'].setdefault(d, []).extend(nights)

    if customer is not None:
        entry = customers.get(('user', customer.id))
        customers = {('user', customer.id): entry} if entry else {}
    if target_dog is not None:
        entry = customers.get(('dog', target_dog.id))
        customers = {('dog', target_dog.id): entry} if entry else {}

    manual = 0
    if customer is None and target_dog is None:
        app_billed = {}
        for key, entry in customers.items():
            owner, entry_dog = entry['owner'], entry['dog']
            if owner is not None:
                mode = getattr(getattr(owner, 'profile', None), 'billing_mode', 'MANUAL')
            else:
                mode = entry_dog.billing_mode
            if mode == 'APP':
                app_billed[key] = entry
            else:
                manual += 1
        customers = app_billed

    billed_customers = set(
        Invoice.objects.filter(period_year=year, period_month=month, customer__isnull=False)
        .exclude(status='VOID').values_list('customer_id', flat=True)
    )
    # A dog on any active invoice for the period is already billed, whichever
    # invoice (its own, or its owner's) carries it.
    billed_dogs = _dogs_billed_elsewhere(year, month)

    created = []
    skipped = 0
    for entry in customers.values():
        owner, billed_dog = entry['owner'], entry['dog']
        if (owner is not None and owner.id in billed_customers) or (billed_dog is not None and billed_dog.id in billed_dogs):
            skipped += 1
            continue
        daycare = {d: v for d, v in entry['daycare'].items() if d.id not in billed_dogs}
        boarding = {d: v for d, v in entry['boarding'].items() if d.id not in billed_dogs}
        if not daycare and not boarding:
            skipped += 1
            continue
        with transaction.atomic():
            invoice = Invoice.objects.create(
                customer=owner,
                billed_dog=billed_dog,
                period_year=year,
                period_month=month,
                status='DRAFT',
                created_by=created_by,
            )
            total = _build_lines(invoice, daycare)
            total += _build_boarding_lines(invoice, boarding)
            invoice.total = total
            invoice.save(update_fields=['total', 'updated_at'])
        push_draft_to_xero(invoice)
        created.append(invoice)
    return created, skipped, manual


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
        rate, note = resolve_day_rate(dog, customer=invoice.customer)
        split_discount = discount > 0
        standard = [d for d, owner_transport in days if not (owner_transport and split_discount)]
        discounted = [d for d, owner_transport in days if owner_transport and split_discount]
        if standard:
            line_total = rate * len(standard)
            InvoiceLine.objects.create(
                invoice=invoice,
                dog=dog,
                description=f"Daycare — {dog.name} ({len(standard)} day{'s' if len(standard) != 1 else ''} @ £{rate}, {note})",
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
                    f"@ £{discounted_rate}, {note}, owner drop-off & pick-up)"
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


def _dogs_billed_elsewhere(year, month, exclude=None):
    """Ids of dogs already carried by a non-VOID invoice for the period
    (as its billed dog or on one of its lines), optionally ignoring one."""
    active = Invoice.objects.filter(period_year=year, period_month=month).exclude(status='VOID')
    if exclude is not None:
        active = active.exclude(pk=exclude.pk)
    billed = set(active.filter(billed_dog__isnull=False).values_list('billed_dog_id', flat=True))
    billed.update(
        InvoiceLine.objects.filter(invoice__in=active, dog__isnull=False).values_list('dog_id', flat=True))
    return billed


def _adjustments_total(invoice):
    return invoice.lines.filter(is_adjustment=True).aggregate(total=Sum('line_total'))['total'] or Decimal('0.00')


def regenerate_draft(invoice):
    """Rebuild a DRAFT invoice's attendance/boarding lines from current data.

    Staff-entered adjustment lines are preserved — regeneration corrects the
    attendance-derived lines, it doesn't undo manual amendments.
    """
    if invoice.status != 'DRAFT':
        raise ValueError('Only draft invoices can be regenerated.')
    # A dog-name invoice's attendance sits under the dog's owner (or None
    # when it has no client); only its own dog's charges belong on it.
    owner_key = invoice.billed_dog.owner if invoice.billed_dog is not None else invoice.customer
    daycare = attendance_for_month(invoice.period_year, invoice.period_month).get(owner_key, {})
    boarding = boarding_nights_for_month(invoice.period_year, invoice.period_month).get(owner_key, {})
    if invoice.billed_dog is not None:
        daycare = {dog: days for dog, days in daycare.items() if dog.id == invoice.billed_dog_id}
        boarding = {dog: nights for dog, nights in boarding.items() if dog.id == invoice.billed_dog_id}
    else:
        # Dogs raised on their own invoice for the period stay off the owner's.
        elsewhere = _dogs_billed_elsewhere(invoice.period_year, invoice.period_month, exclude=invoice)
        daycare = {dog: days for dog, days in daycare.items() if dog.id not in elsewhere}
        boarding = {dog: nights for dog, nights in boarding.items() if dog.id not in elsewhere}
    with transaction.atomic():
        invoice.lines.filter(is_adjustment=False).delete()
        invoice.total = (
            _build_lines(invoice, daycare)
            + _build_boarding_lines(invoice, boarding)
            + _adjustments_total(invoice)
        )
        invoice.save(update_fields=['total', 'updated_at'])
    _sync_draft_lines_to_xero(invoice)
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
    _sync_draft_lines_to_xero(invoice)
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
    _sync_draft_lines_to_xero(invoice)
    return invoice


def send_invoice(invoice, user=None):
    """Send a DRAFT invoice: push to Xero, ask Xero to email it to the customer,
    mark it SENT and notify the owner.

    Claiming the invoice is the first thing this does, under a row lock. The
    Xero round-trip takes seconds and the app times out at 30s, so a staff
    member who retries a slow "send" would otherwise run this twice against the
    same still-DRAFT row and raise two real invoices in Xero — two invoice
    numbers, two emails to the customer, and only the second id recorded here.

    The status flip is deliberately *after* the Xero push. It used to come
    first, which left any Xero failure (timeout, 429, outage) showing SENT with
    no xero_invoice_id: never emailed, pay_url 404ing, not picked up by a retry
    of send_all (which only looks at DRAFT) — yet the customer had already been
    pushed "your invoice is ready".
    """
    from django.db import transaction

    # Claim the row first, under a lock, so a concurrent call sees SENDING
    # rather than DRAFT and refuses. Only the caller that wins the race does any
    # Xero I/O.
    with transaction.atomic():
        locked = Invoice.objects.select_for_update().get(pk=invoice.pk)
        if locked.status != 'DRAFT':
            raise ValueError('Only draft invoices can be sent.')
        locked.status = 'SENDING'
        locked.save(update_fields=['status', 'updated_at'])
    invoice.refresh_from_db()

    def _release_to_draft():
        invoice.status = 'DRAFT'
        invoice.save(update_fields=['status', 'updated_at'])

    due_date = timezone.now().date() + timezone.timedelta(days=PAYMENT_TERMS_DAYS)
    try:
        pushed = push_invoice_to_xero(invoice, due_date=due_date)
        if pushed:
            email_invoice_from_xero(invoice)
    except BaseException:
        # push_invoice_to_xero is already no-raise, so this is belt-and-braces:
        # nothing short of the process being killed outright may leave an
        # invoice stranded in SENDING, where neither send nor send_all (both
        # DRAFT-only) would ever pick it up again.
        logger.exception('Unexpected error pushing invoice %s to Xero', invoice.pk)
        _release_to_draft()
        raise

    if XeroConnection.load().is_connected and not pushed:
        # Xero is configured but rejected us. Put the invoice back so a retry
        # picks it up, rather than leaving a SENT invoice the customer can
        # neither see nor pay.
        _release_to_draft()
        raise XeroSendFailed(invoice.xero_sync_error or 'Could not send the invoice to Xero.')

    invoice.status = 'SENT'
    invoice.sent_at = timezone.now()
    invoice.due_date = due_date
    invoice.save(update_fields=['status', 'sent_at', 'due_date', 'updated_at'])

    # Dog-name invoices have no app user to notify — they're emailed from Xero.
    if invoice.customer is not None:
        send_push_notification(
            invoice.customer,
            'New invoice',
            f'Your daycare invoice for {invoice.period_label} is ready: £{invoice.total}.',
            data={'type': 'invoice', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
        )
    return invoice


def push_invoice_to_xero(invoice, due_date=None):
    """Make sure the invoice exists in Xero as an APPROVED invoice, and store
    the ids + online payment URL.

    If the invoice is already in Xero as a draft (the normal case — drafts are
    raised at generation), this approves that draft rather than creating a
    second invoice. Best-effort: returns True on success, False when Xero is
    not connected or the push failed (error stored on ``xero_sync_error``).
    Never raises.
    """
    if not XeroConnection.load().is_connected:
        return False
    due_date = due_date or invoice.due_date or timezone.now().date()
    try:
        if invoice.xero_invoice_id:
            if invoice.status in ('DRAFT', 'SENDING'):
                # Still a draft on both sides: approve the Xero copy.
                xero.authorise_invoice(invoice.xero_invoice_id, due_date)
                invoice.xero_sync_error = ''
                invoice.save(update_fields=['xero_sync_error', 'updated_at'])
        else:
            contact_id = _resolve_contact_id(invoice)
            xero_id, xero_number = xero.create_invoice(invoice, contact_id, status='AUTHORISED', due_date=due_date)
            invoice.xero_invoice_id = xero_id
            invoice.xero_invoice_number = xero_number
            invoice.xero_sync_error = ''
            invoice.save(update_fields=['xero_invoice_id', 'xero_invoice_number', 'xero_sync_error', 'updated_at'])
    except xero.XeroError as exc:
        logger.error('Failed to push invoice #%s to Xero: %s', invoice.id, exc)
        invoice.xero_sync_error = str(exc)
        invoice.save(update_fields=['xero_sync_error', 'updated_at'])
        return False
    _backfill_online_url(invoice)
    return True


def push_draft_to_xero(invoice):
    """Raise a freshly generated draft in Xero as a DRAFT invoice.

    Best-effort and idempotent (no-op when already in Xero or Xero is not
    connected); a failure is stored on ``xero_sync_error`` and the app draft
    carries on — ``send_invoice`` will create the Xero copy then instead.
    Returns True when the invoice is in Xero afterwards.
    """
    if invoice.xero_invoice_id:
        return True
    if not XeroConnection.load().is_connected:
        return False
    try:
        contact_id = _resolve_contact_id(invoice)
        xero_id, xero_number = xero.create_invoice(
            invoice, contact_id, status='DRAFT',
            due_date=timezone.now().date() + timezone.timedelta(days=PAYMENT_TERMS_DAYS),
        )
    except xero.XeroError as exc:
        logger.error('Failed to raise draft invoice #%s in Xero: %s', invoice.id, exc)
        invoice.xero_sync_error = str(exc)
        invoice.save(update_fields=['xero_sync_error', 'updated_at'])
        return False
    invoice.xero_invoice_id = xero_id
    invoice.xero_invoice_number = xero_number
    invoice.xero_sync_error = ''
    invoice.save(update_fields=['xero_invoice_id', 'xero_invoice_number', 'xero_sync_error', 'updated_at'])
    return True


def _sync_draft_lines_to_xero(invoice):
    """Mirror an edited app draft's lines onto its Xero draft (best-effort)."""
    if invoice.status != 'DRAFT' or not invoice.xero_invoice_id:
        return False
    if not XeroConnection.load().is_connected:
        return False
    try:
        xero.update_draft_invoice(invoice.xero_invoice_id, invoice)
    except xero.XeroError as exc:
        logger.error('Failed to update Xero draft for invoice #%s: %s', invoice.id, exc)
        invoice.xero_sync_error = f'Xero draft update failed: {exc}'
        invoice.save(update_fields=['xero_sync_error', 'updated_at'])
        return False
    if invoice.xero_sync_error:
        invoice.xero_sync_error = ''
        invoice.save(update_fields=['xero_sync_error', 'updated_at'])
    return True


def _backfill_online_url(invoice):
    """Fetch the customer-facing payment URL if missing (best-effort). Xero
    only issues one once the invoice is approved."""
    if invoice.xero_online_url or not invoice.xero_invoice_id:
        return
    try:
        invoice.xero_online_url = xero.get_online_invoice_url(invoice.xero_invoice_id)
        invoice.save(update_fields=['xero_online_url', 'updated_at'])
    except xero.XeroError as exc:
        logger.warning('Could not fetch Xero online invoice URL: %s', exc)


def _resolve_contact_id(invoice):
    """The Xero ContactID to invoice: the pinned id when the customer/dog has
    one, otherwise an email/name match (created if missing) whose result is
    pinned for next time. Pinning keeps invoices attached to the customer's
    existing Xero contact — long-standing customers were invoiced by hand in
    Xero, and a fresh name/email lookup can miss their contact and create a
    duplicate. A stale pin (contact deleted in Xero) surfaces as a push error;
    unpin it on the reconciliation screen."""
    if invoice.customer is not None:
        profile = getattr(invoice.customer, 'profile', None)
        if profile is not None and profile.xero_contact_id:
            return profile.xero_contact_id
        contact_id = xero.find_or_create_contact(invoice.customer)
        if profile is not None:
            profile.xero_contact_id = contact_id
            profile.save(update_fields=['xero_contact_id'])
        return contact_id
    # Dog-name invoice: the dog's pinned contact when it has one (learned
    # from the contact the business assigned in Xero last time), otherwise
    # the shared "unassigned" placeholder for the business to reassign.
    dog = invoice.billed_dog
    if dog is not None and dog.xero_contact_id:
        return dog.xero_contact_id
    return _unassigned_contact_id()


def _unassigned_contact_id():
    conn = XeroConnection.load()
    if not conn.unassigned_contact_id:
        conn.unassigned_contact_id = xero.find_or_create_contact_by_name(UNASSIGNED_CONTACT_NAME)
        conn.save(update_fields=['unassigned_contact_id', 'updated_at'])
    return conn.unassigned_contact_id


def email_invoice_from_xero(invoice):
    """Ask Xero to email the invoice to its contact — the same branded email
    customers got when invoices were raised by hand in Xero.

    Gated by ``settings.XERO_EMAIL_INVOICES``. Best-effort and idempotent:
    no-op unless the invoice is in Xero and hasn't been emailed yet; failures
    (e.g. the Xero contact has no email address) are stored on
    ``xero_sync_error`` and never raised.
    """
    from django.conf import settings

    if not getattr(settings, 'XERO_EMAIL_INVOICES', False):
        return False
    if not invoice.xero_invoice_id or invoice.xero_emailed_at:
        return False
    try:
        xero.email_invoice(invoice.xero_invoice_id)
    except xero.XeroError as exc:
        logger.error('Failed to email invoice #%s from Xero: %s', invoice.id, exc)
        invoice.xero_sync_error = f'Xero email failed: {exc}'
        invoice.save(update_fields=['xero_sync_error', 'updated_at'])
        return False
    invoice.xero_emailed_at = timezone.now()
    invoice.save(update_fields=['xero_emailed_at', 'updated_at'])
    return True


def refresh_payment_state(invoice):
    """Recompute ``amount_paid`` and the paid/part-paid status from the
    payments ledger. DRAFT and VOID invoices are left alone."""
    paid = invoice.payments.aggregate(total=Sum('amount'))['total'] or Decimal('0.00')
    invoice.amount_paid = paid
    update_fields = ['amount_paid', 'updated_at']
    # SENDING is a transient claim held by send_invoice; overwriting it here
    # would undo the double-send guard mid-push.
    if invoice.status not in ('DRAFT', 'SENDING', 'VOID'):
        # `total > 0` used to be an AND here, which pinned a £0.00 invoice at
        # SENT forever: nothing can ever be "paid", record_manual_payment
        # rejects amounts <= 0, and send_invoice_reminders chases it every day.
        # A zero-total invoice is settled by definition.
        if invoice.total <= 0 or paid >= invoice.total:
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

    if invoice.customer is not None:
        send_push_notification(
            invoice.customer,
            'Payment received',
            f'We received £{amount} towards your {invoice.period_label} invoice. Thank you!',
            data={'type': 'invoice_payment', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
        )
    send_staff_notification(
        'Payment recorded',
        f'£{amount} ({payment.get_method_display()}) recorded on {invoice.billed_name}\'s {invoice.period_label} invoice.',
        data={'type': 'invoice_payment', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
        permission='can_manage_payments',
        exclude_user=recorded_by,
    )
    return payment


def sync_invoices_from_xero():
    """Pull status back from Xero for drafts and open invoices.

    Drafts raised in Xero: an approval there (AUTHORISED/PAID) marks the app
    copy SENT — adopting Xero's total (any difference booked as an "amended in
    Xero" adjustment line so the lines still add up), due date and number —
    and pins the contact the draft was assigned to on the dog; a draft deleted
    in Xero is VOIDed here.

    Open invoices: imports Xero payments as PaymentRecords (deduped by
    ``xero_payment_id``) and, when Xero reports more paid than the ledger
    accounts for (credit notes, prepayments, overpayments), books the
    difference as a synthetic adjustment so the totals stay honest. Returns
    counts for logging.
    """
    counts = {'checked': 0, 'payments_imported': 0, 'paid': 0, 'approved': 0, 'voided': 0, 'errors': 0}
    if not XeroConnection.load().is_connected:
        return counts

    open_invoices = list(
        Invoice.objects
        .filter(status__in=('DRAFT', 'SENT', 'PART_PAID'))
        .exclude(xero_invoice_id='')
        .select_related('billed_dog', 'customer__profile')
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
            _learn_contact(invoice, remote)
            if invoice.status == 'DRAFT':
                remote_status = remote.get('Status', '')
                if remote_status in XERO_CANCELLED_STATUSES:
                    invoice.status = 'VOID'
                    invoice.xero_last_synced_at = now
                    invoice.save(update_fields=['status', 'xero_last_synced_at', 'updated_at'])
                    counts['voided'] += 1
                    continue
                if remote_status not in XERO_APPROVED_STATUSES:
                    invoice.xero_last_synced_at = now
                    invoice.save(update_fields=['xero_last_synced_at', 'updated_at'])
                    continue
                _mark_sent_from_xero(invoice, remote)
                counts['approved'] += 1
            was_paid = invoice.status == 'PAID'
            counts['payments_imported'] += _import_remote_payments(invoice, remote)
            refresh_payment_state(invoice)
            invoice.xero_last_synced_at = now
            invoice.save(update_fields=['xero_last_synced_at', 'updated_at'])
            if invoice.status == 'PAID' and not was_paid:
                counts['paid'] += 1
                _notify_invoice_paid(invoice)
    return counts


def _mark_sent_from_xero(invoice, remote):
    """A draft approved inside Xero becomes SENT here. Xero's copy is the one
    the customer received, so its total, due date and number win."""
    remote_total = Decimal(str(remote.get('Total', invoice.total) or 0)).quantize(Decimal('0.01'))
    if remote_total != invoice.total:
        difference = remote_total - invoice.total
        InvoiceLine.objects.create(
            invoice=invoice,
            description='Amended in Xero',
            quantity=1,
            unit_price=difference,
            line_total=difference,
            is_adjustment=True,
        )
        invoice.total = remote_total
    invoice.status = 'SENT'
    invoice.sent_at = timezone.now()
    invoice.due_date = _parse_xero_date(remote.get('DueDate')) or (
        timezone.now().date() + timezone.timedelta(days=PAYMENT_TERMS_DAYS))
    if remote.get('InvoiceNumber'):
        invoice.xero_invoice_number = remote['InvoiceNumber']
    invoice.xero_sync_error = ''
    invoice.save(update_fields=[
        'status', 'sent_at', 'due_date', 'total', 'xero_invoice_number', 'xero_sync_error', 'updated_at'])
    _backfill_online_url(invoice)
    if invoice.customer is not None:
        send_push_notification(
            invoice.customer,
            'New invoice',
            f'Your daycare invoice for {invoice.period_label} is ready: £{invoice.total}.',
            data={'type': 'invoice', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
        )


def _learn_contact(invoice, remote):
    """Pin the Xero contact an invoice ended up on, so the next invoice for
    the same dog/customer is raised against it directly. Ignores the
    "unassigned" placeholder — that's the one waiting to be replaced."""
    contact_id = (remote.get('Contact') or {}).get('ContactID', '')
    if not contact_id or contact_id == XeroConnection.load().unassigned_contact_id:
        return
    dog = invoice.billed_dog
    if invoice.customer is None and dog is not None and dog.xero_contact_id != contact_id:
        dog.xero_contact_id = contact_id
        dog.save(update_fields=['xero_contact_id'])
        return
    profile = getattr(invoice.customer, 'profile', None) if invoice.customer is not None else None
    if profile is not None and not profile.xero_contact_id:
        profile.xero_contact_id = contact_id
        profile.save(update_fields=['xero_contact_id'])


def _import_remote_payments(invoice, remote):
    """Import unseen payments from a Xero invoice dict; returns count added.

    Idempotent, and safe to run concurrently: this is reachable both from the
    */30 sync cron and from the staff "Sync with Xero" button, so a Python-side
    dedupe check alone would let two overlapping runs import the same payment
    twice and flip a part-paid invoice to PAID. get_or_create leans on the
    uniq_xero_payment_per_invoice constraint to settle the race in the database.
    """
    imported = 0
    for remote_payment in remote.get('Payments') or []:
        payment_id = remote_payment.get('PaymentID', '')
        if not payment_id:
            continue
        _, created = PaymentRecord.objects.get_or_create(
            invoice=invoice,
            xero_payment_id=payment_id,
            defaults={
                'amount': Decimal(str(remote_payment.get('Amount', 0))),
                'method': 'XERO_ONLINE',
                'source': 'XERO',
                'payment_date': (_parse_xero_date(remote_payment.get('Date'))
                                 or timezone.now().date()),
            },
        )
        if created:
            imported += 1

    # Credits/prepayments/overpayments don't appear in Payments[]; if Xero says
    # more has been settled than our ledger holds, book the difference.
    remote_paid = Decimal(str(remote.get('AmountPaid', 0) or 0)) + Decimal(str(remote.get('AmountCredited', 0) or 0))
    local_paid = invoice.payments.aggregate(total=Sum('amount'))['total'] or Decimal('0.00')
    if remote_paid > local_paid:
        # Give the adjustment a deterministic key too, so a concurrent (or
        # simply repeated) sync tops the balance up once rather than compounding
        # the same difference on every run.
        _, created = PaymentRecord.objects.get_or_create(
            invoice=invoice,
            xero_payment_id=f'balance:{invoice.xero_invoice_id}:{remote_paid}'[:64],
            defaults={
                'amount': remote_paid - local_paid,
                'method': 'OTHER',
                'source': 'XERO',
                'payment_date': timezone.now().date(),
                'notes': 'Xero balance adjustment (credit/prepayment).',
            },
        )
        if created:
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
    if invoice.customer is not None:
        send_push_notification(
            invoice.customer,
            'Payment received',
            f'Thank you — your {invoice.period_label} invoice is paid in full.',
            data={'type': 'invoice_payment', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
        )
    send_staff_notification(
        'Invoice paid',
        f'{invoice.billed_name}\'s {invoice.period_label} invoice (£{invoice.total}) is now paid.',
        data={'type': 'invoice_payment', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
        permission='can_manage_payments',
    )
