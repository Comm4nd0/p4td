"""Monthly customer billing.

Invoices are raised **in advance**: the invoice for a month charges every
day the dog is booked in that month as the roster stands today
(``booked_days_for_month`` — the regular weekly days plus approved
additions, minus approved cancellations, staff removals, closure days and
days inside a boarding stay), and then catches up earlier extras: days the
dog actually attended (a non-``REMOVED`` ``DailyDogAssignment`` row —
``UNASSIGNED`` means it attended without a staff member — or an approved
extra day that never got a row) that no invoice has charged yet. A day is
charged once, ever: ``_billed_ledger`` reads back the dates on every
non-VOID invoice line, so a day billed in advance is not billed again when
it is attended, and a day added after the invoice went out is picked up on
the next invoice — last month's always, and up to ``CATCH_UP_MONTHS`` back
for months the app itself invoiced the dog for (``charges_for_month`` has
the rule, and why hand-invoiced months are never reached into).
Booked days are charged whether or not the dog turns up — a refund for a
day cancelled after invoicing is a staff adjustment.

One invoice per customer per month, one line per dog per kind (booked days,
last month's extras, boarding nights), at ``Dog.daily_rate`` (a payment
manager's per-dog override), else the customer's per-client rate, else the
tier for how many days a week the dog is *booked in*
(``ServicePricing.day_care_tier``: one day, two to four, five). The tier
follows the booking, not the month's attendance — a one-day-a-week dog that
adds an extra day pays the one-day rate for both, which the line
description spells out.

Approved boarding stays bill separately at a per-night rate
(``Dog.boarding_rate`` falling back to ``ServicePricing.boarding_price_per_night``):
a billable night is a stay date before the checkout day, clamped to the
billing month. Boarding REPLACES the daycare charge for the days it covers —
``attendance_for_month`` subtracts ``_boarded_dog_days``, so a boarded dog is
never charged for both on the same date. (This paragraph previously claimed the
opposite, which is a dangerous thing to leave lying around next to a billing
engine: anyone "fixing the code to match the docs" would double-charge every
boarding customer.) When a stay is booked *after* the invoice that charged
its days as daycare went out, the nights are charged on the next invoice and
each such day comes back as a "Credit" line beside its night, so the customer
still pays for the night only. Lines carry no kind column: ``line_kind`` reads
it from the description prefix ("Boarding", "Credit", else daycare), so keep
those prefixes.

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

Dates are the business's dates: ``timezone.localdate()`` (Europe/London),
never ``timezone.now().date()``, which is UTC and a day behind for the hour
after midnight in summer.
"""
import calendar as _calendar
import logging
from datetime import date as date_cls, timedelta
from decimal import Decimal

from django.db import IntegrityError, transaction
from django.db.models import Q, Sum
from django.utils import timezone

from . import xero
from .models import BoardingRequest, DailyDogAssignment, Dog, Invoice, InvoiceLine, PaymentRecord, XeroConnection
from .scheduling import ScheduleIndex, daterange
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

# How far back an invoice can reach for days and nights that were never
# charged, at most. Only into months the app itself invoiced the dog for — see
# charges_for_month. How far it actually reaches is the BILLING_CATCH_UP_MONTHS
# setting, which defaults to 1 (last month only, as it always was): charging a
# customer for a day from months ago is the business's decision to switch on,
# not something a code change should start doing by itself.
CATCH_UP_MONTHS = 12


def catch_up_months():
    from django.conf import settings
    try:
        months = int(getattr(settings, 'BILLING_CATCH_UP_MONTHS', 1))
    except (TypeError, ValueError):
        months = 1
    return max(1, min(months, CATCH_UP_MONTHS))

# send_invoice holds SENDING for the length of a Xero round-trip (seconds; the
# web worker is killed at 120s). A row still SENDING after this long was
# abandoned mid-send, and the Xero sync settles it.
SENDING_STALE_MINUTES = 10

# What an attendance-derived line charges; see line_kind.
LINE_DAYCARE = 'daycare'
LINE_BOARDING = 'boarding'
LINE_CREDIT = 'credit'
CREDIT_PREFIX = 'Credit — '


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


def _boarded_dog_days_between(start, end):
    """(dog_id, date) pairs covered by an approved boarding stay between two
    dates, arrival through checkout inclusive. The boarding charge covers the
    whole stay, so daycare attendance on these days is not billed separately."""
    covered = set()
    requests = (
        BoardingRequest.objects
        .filter(status='APPROVED', start_date__lte=end, end_date__gte=start)
        .prefetch_related('dogs')
    )
    for request in requests:
        first = max(request.start_date, start)
        last = min(request.end_date, end)
        for dog in request.dogs.all():
            for offset in range((last - first).days + 1):
                covered.add((dog.id, first + timedelta(days=offset)))
    return covered


def _boarded_dog_days(year, month):
    """``_boarded_dog_days_between`` for one calendar month."""
    return _boarded_dog_days_between(*_month_bounds(year, month))


def _attendance_between(start, end):
    """Billable attended days per dog between two dates (inclusive), as
    ``{dog_id: (dog, [(date, owner_transport), ...])}`` in date order.

    A day counts when the dog has a non-``REMOVED`` ``DailyDogAssignment``
    row for it, **or** when an approved extra day (ADD_DAY, or the new date
    of a CHANGE) put the dog on a date that has already passed and nobody
    ever gave it a board row. Approving an extra day creates no row — it
    appears when a driver is named — and a dog whose owner drives both ways
    is hidden from the unassigned list, so its extra days never got one and
    were never invoiced. A date with *any* row is decided by the row (a
    ``REMOVED`` one means staff took the dog off), a later approved
    cancellation wins over the addition (``effective_change_actions``), and
    a CLOSED day counts for nobody.

    ``owner_transport`` marks days the owner handled both transport legs.
    Days inside an approved boarding stay are excluded (the boarding charge
    covers them).
    """
    from .models import ClosureDay
    from .scheduling import effective_change_actions

    boarded = _boarded_dog_days_between(start, end)
    assignments = (
        DailyDogAssignment.objects
        .filter(date__range=(start, end))
        .select_related('dog__owner__profile')
        .order_by('date')
    )
    found = {}        # dog_id -> (dog, {date: owner_transport})
    has_row = set()   # (dog_id, date) with any row, REMOVED included
    for assignment in assignments:
        has_row.add((assignment.dog_id, assignment.date))
        if assignment.status == 'REMOVED' or (assignment.dog_id, assignment.date) in boarded:
            continue
        owner_transport = assignment.effective_owner_brings and assignment.effective_owner_collects
        found.setdefault(assignment.dog_id, (assignment.dog, {}))[1][assignment.date] = owner_transport

    # Approved extra days that never got a row. Past dates only: a future one
    # may still be given a driver, and until then it is a booking, which
    # booked_days_for_month already charges.
    last_past = min(end, timezone.localdate() - timedelta(days=1))
    if start <= last_past:
        adds_by_date, _ = effective_change_actions(start, last_past)
        closed = set(
            ClosureDay.objects
            .filter(date__range=(start, last_past), closure_type='CLOSED')
            .values_list('date', flat=True)
        )
        missing = [
            (dog_id, day)
            for day, dog_ids in adds_by_date.items() if day not in closed
            for dog_id in dog_ids
            if (dog_id, day) not in has_row and (dog_id, day) not in boarded
        ]
        if missing:
            dogs = Dog.objects.select_related('owner__profile').in_bulk({dog_id for dog_id, _ in missing})
            for dog_id, day in missing:
                dog = found[dog_id][0] if dog_id in found else dogs.get(dog_id)
                if dog is None:
                    continue
                owner_transport = dog.owner_brings_default and dog.owner_collects_default
                found.setdefault(dog_id, (dog, {}))[1][day] = owner_transport

    return {
        dog_id: (dog, sorted(days.items()))
        for dog_id, (dog, days) in found.items() if days
    }


def attendance_for_month(year, month):
    """Billable attended days per owner per dog for a calendar month.

    Returns ``{owner: {dog: [(date, owner_transport), ...]}}`` — see
    ``_attendance_between`` for what counts as attended. Ownerless dogs group
    under None — they get per-dog invoices in the dog's name rather than
    being silently unbilled.
    """
    by_owner = {}
    for dog, days in _attendance_between(*_month_bounds(year, month)).values():
        by_owner.setdefault(dog.owner, {})[dog] = days
    return by_owner


def _boarding_nights_between(start, end):
    """Billable boarding nights per dog between two dates (inclusive), as
    ``{dog_id: (dog, [night, ...])}`` in date order. A billable night is a
    stay date strictly before the checkout day (Fri→Sun = 2 nights)."""
    requests = (
        BoardingRequest.objects
        .filter(status='APPROVED', start_date__lte=end, end_date__gte=start)
        .prefetch_related('dogs__owner__profile')
    )
    found = {}
    for request in requests:
        first_night = max(request.start_date, start)
        # Last billable night is the day before checkout, clamped to the range.
        last_night = min(request.end_date - timedelta(days=1), end)
        if first_night > last_night:
            continue
        nights = [
            first_night + timedelta(days=offset)
            for offset in range((last_night - first_night).days + 1)
        ]
        for dog in request.dogs.all():
            found.setdefault(dog.id, (dog, set()))[1].update(nights)
    return {dog_id: (dog, sorted(nights)) for dog_id, (dog, nights) in found.items()}


def boarding_nights_for_month(year, month):
    """Billable boarding nights per DOG OWNER per dog for a calendar month.

    Returns ``{owner: {dog: [night dates]}}``. A billable night is a stay date
    strictly before the checkout day (Fri→Sun = 2 nights), clamped to the
    month so a stay spanning months bills each month's nights separately.

    Charges always follow the dog's assigned client — never whoever created
    the booking (staff often book on a client's behalf). Dogs with no client
    group under None and get per-dog invoices in the dog's name.
    """
    by_owner = {}
    for dog, nights in _boarding_nights_between(*_month_bounds(year, month)).values():
        by_owner.setdefault(dog.owner, {})[dog] = nights
    return by_owner


def _month_bounds(year, month):
    return date_cls(year, month, 1), date_cls(year, month, _calendar.monthrange(year, month)[1])


def previous_month(year, month):
    return (year - 1, 12) if month == 1 else (year, month - 1)


def booked_days_for_month(year, month, regular_only=False):
    """``{dog: [(date, owner_transport), ...]}`` — every day each dog is booked
    in for the month, as the roster stands now: its regular weekly days plus
    approved additions, minus approved cancellations, staff removals and
    CLOSED closure days (``ScheduleIndex``), and minus days inside an approved
    boarding stay (the boarding charge covers those). ``owner_transport``
    comes from the day's assignment row when one exists, else the dog's
    transport defaults.

    ``regular_only`` ignores assignment rows — the schedule as booked, not as
    attended — which is what a by-hand invoice for a past month would have
    charged.
    """
    start, end = _month_bounds(year, month)
    index = ScheduleIndex(start, end)
    rows = {
        (row.dog_id, row.date): row
        for row in DailyDogAssignment.objects.filter(date__range=(start, end))
        .exclude(status='REMOVED').select_related('dog')
    }
    dogs = {d.id: d for d in Dog.objects.select_related('owner__profile')}

    def scheduled(day):
        if regular_only:
            closure = index.closure(day)
            if closure and closure.closure_type == 'CLOSED':
                return set()
            return (index.weekday_dogs.get(day.isoweekday(), set()) | index.adds_by_date.get(day, set())) \
                - index.cancels_by_date.get(day, set())
        return index.attending_dog_ids(day)

    booked = {}
    for day in daterange(start, end):
        for dog_id in scheduled(day) - index.boarding_dog_ids(day):
            dog = dogs.get(dog_id)
            if dog is None:
                continue
            row = rows.get((dog_id, day))
            if row is not None:
                owner_transport = row.effective_owner_brings and row.effective_owner_collects
            else:
                owner_transport = dog.owner_brings_default and dog.owner_collects_default
            booked.setdefault(dog, []).append((day, owner_transport))
    return booked


def line_kind(description):
    """What an attendance-derived invoice line charges, read from the
    description the builder gave it: a boarding night, a credit for a daycare
    day a boarding night replaced, or (everything else, including the
    summary lines older invoices carried) daycare."""
    description = description or ''
    if description.startswith('Boarding'):
        return LINE_BOARDING
    if description.startswith('Credit'):
        return LINE_CREDIT
    return LINE_DAYCARE


class _DogLedger:
    """What non-VOID invoices already say about one dog."""
    __slots__ = ('daycare', 'boarding', 'credited', 'months')

    def __init__(self):
        # date -> (amount charged for the day, invoice status, invoice period label)
        self.daycare = {}
        # nights charged
        self.boarding = set()
        # dates a daycare charge has been credited back for
        self.credited = set()
        # (year, month) the app invoiced this dog for *as that month's own
        # invoice* — a line dated inside its invoice's period. A day caught up
        # on a later invoice does not make its month one of these.
        self.months = set()

    @property
    def dates(self):
        return set(self.daycare) | self.boarding


_NO_LEDGER = _DogLedger()


def _billed_ledger(exclude_invoice=None):
    """``{dog_id: _DogLedger}`` from every attendance line on a non-VOID
    invoice, optionally ignoring one invoice (the one being rebuilt)."""
    lines = InvoiceLine.objects.filter(is_adjustment=False, dog__isnull=False).exclude(invoice__status='VOID')
    if exclude_invoice is not None:
        lines = lines.exclude(invoice=exclude_invoice)
    ledger = {}
    rows = lines.order_by('id').values_list(
        'dog_id', 'attendance_dates', 'description', 'unit_price',
        'invoice__status', 'invoice__period_year', 'invoice__period_month',
    )
    for dog_id, dates, description, unit_price, status, period_year, period_month in rows:
        entry = ledger.setdefault(dog_id, _DogLedger())
        kind = line_kind(description)
        label = f'{_calendar.month_name[period_month]} {period_year}'
        for iso in dates or []:
            try:
                day = date_cls.fromisoformat(iso)
            except (TypeError, ValueError):
                continue
            if kind == LINE_CREDIT:
                entry.credited.add(day)
                continue
            if kind == LINE_BOARDING:
                entry.boarding.add(day)
            else:
                entry.daycare.setdefault(day, (unit_price, status, label))
            if (day.year, day.month) == (period_year, period_month):
                entry.months.add((period_year, period_month))
    return ledger


def _billed_dates_by_dog(exclude_invoice=None):
    """``{dog_id: {date, ...}}`` of every day already charged on a non-VOID
    invoice line (booked, extra or boarding), optionally ignoring one invoice
    (the one being rebuilt)."""
    return {dog_id: entry.dates for dog_id, entry in _billed_ledger(exclude_invoice).items()}


def _months_before(year, month, count):
    """The first day of the month ``count`` months before (year, month)."""
    index = year * 12 + (month - 1) - count
    return date_cls(index // 12, index % 12 + 1, 1)


def charges_for_month(year, month, exclude_invoice=None):
    """Everything to charge on the month's invoices, per owner per dog::

        {owner_or_None: {dog: {
            'daycare': [(date, owner_transport)],       # booked this month
            'extra_daycare': [(date, owner_transport)], # attended earlier, unbilled
            'boarding': [night, ...],                   # this month's nights
            'extra_boarding': [night, ...],             # earlier nights, unbilled
            'credits': [(date, amount, invoice label)], # see below
        }}}

    **A date is charged once.** A daycare day is left out when the date is
    already on another non-VOID invoice, as a day or as a boarding night. A
    boarding night is left out when the night is already charged.

    **A boarding night on a date already charged as a daycare day** — the stay
    was booked after the invoice for that day went out — is charged as a
    night, and the daycare charge comes back as a credit (``credits``), so
    the customer ends up paying for the night only. Boarding replaces
    daycare; it used to be that such a night was simply dropped, because the
    date was "already billed". The credit is given once per date
    (``_DogLedger.credited``), and never while the daycare charge sits on
    another invoice that is still a draft: regenerating that draft takes the
    day off it, so the night waits for that (or for the draft to be sent).

    **Catching up.** Unbilled days and nights from before the period are
    charged now. Last month is handled as it always was: when the app raised
    no invoice of its own for the dog that month, it was invoiced by hand
    (the pre-app way), so the dog's regular booked days for it count as
    charged and only days off that schedule come through. Months before that,
    back to ``CATCH_UP_MONTHS``, are caught up **only where the app itself
    invoiced the dog for that month** — a day added to October in November,
    after November's invoice went out, used to be lost for good. A month the
    app never invoiced is never reached back into, so switching a
    long-standing customer to app billing cannot bill a year of attendance
    that was invoiced by hand.
    """
    start, _ = _month_bounds(year, month)
    prev_year, prev_month = previous_month(year, month)
    prev_start, prev_end = _month_bounds(prev_year, prev_month)
    window_start = _months_before(year, month, catch_up_months())

    booked = booked_days_for_month(year, month)
    attended_before = _attendance_between(window_start, prev_end)
    nights_now = _boarding_nights_between(*_month_bounds(year, month))
    nights_before = _boarding_nights_between(window_start, prev_end)
    ledger = _billed_ledger(exclude_invoice)
    scheduled_prev = {
        dog.id: {d for d, _ in days}
        for dog, days in booked_days_for_month(prev_year, prev_month, regular_only=True).items()
    }

    dogs = {}
    for dog, days in booked.items():
        dogs.setdefault(dog.id, (dog, {}))[1]['daycare'] = days
    for dog_id, (dog, days) in attended_before.items():
        dogs.setdefault(dog_id, (dog, {}))[1]['extra_daycare'] = days
    for dog_id, (dog, nights) in nights_now.items():
        dogs.setdefault(dog_id, (dog, {}))[1]['boarding'] = nights
    for dog_id, (dog, nights) in nights_before.items():
        dogs.setdefault(dog_id, (dog, {}))[1]['extra_boarding'] = nights

    by_owner = {}
    for dog_id, (dog, raw) in dogs.items():
        entry = ledger.get(dog_id, _NO_LEDGER)
        done = entry.dates
        # Last month with no app invoice of its own: invoiced by hand, so its
        # regular days are taken as charged.
        if (prev_year, prev_month) in entry.months:
            assumed = set()
        else:
            assumed = scheduled_prev.get(dog_id, set())

        def may_catch_up(day):
            if day >= prev_start:
                return day not in assumed
            return (day.year, day.month) in entry.months

        credits = []

        def nights_to_charge(nights):
            charged = []
            for night in nights:
                if night in entry.boarding:
                    continue
                day_charge = entry.daycare.get(night)
                if day_charge is not None:
                    amount, status, label = day_charge
                    if status in ('DRAFT', 'SENDING'):
                        # The day is on a draft that has not gone out.
                        # Regenerating it drops the day; until then, charging
                        # the night here would put the date on two invoices.
                        continue
                    if night not in entry.credited:
                        credits.append((night, amount, label))
                charged.append(night)
            return charged

        charges = {
            'daycare': [(d, t) for d, t in raw.get('daycare', []) if d not in done],
            'extra_daycare': [
                (d, t) for d, t in raw.get('extra_daycare', [])
                if d not in done and may_catch_up(d)
            ],
            'boarding': nights_to_charge(raw.get('boarding', [])),
            'extra_boarding': nights_to_charge(
                [n for n in raw.get('extra_boarding', []) if may_catch_up(n)]),
        }
        if not any(charges.values()):
            continue
        charges['credits'] = credits
        by_owner.setdefault(dog.owner, {})[dog] = charges
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
    charges_by_owner = charges_for_month(year, month)

    if target_dog is not None:
        # Per-dog: lift this dog's charges out of its owner's bucket.
        charges_by_owner = {None: {d: v for d, v in charges_by_owner.get(target_dog.owner, {}).items() if d.id == target_dog.id}}

    # Dogs with no client attached bill per dog, in the dog's name, so key
    # those by dog.
    customers = {}
    for owner, dogs in charges_by_owner.items():
        for d, charges in dogs.items():
            key = ('user', owner.id) if owner is not None else ('dog', d.id)
            entry = customers.setdefault(key, {
                'owner': owner,
                'dog': d if owner is None else None,
                'dogs': {},
            })
            entry['dogs'][d] = charges

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

    active = Invoice.objects.filter(period_year=year, period_month=month).exclude(status='VOID')
    billed_customers = set(active.filter(customer__isnull=False).values_list('customer_id', flat=True))
    # A dog on any active invoice for the period is already billed, whichever
    # invoice (its own, or its owner's) carries it.
    billed_dogs = _dogs_billed_elsewhere(year, month)

    # "Skipped" = customers/dogs in scope that already have this period's
    # invoice. Their booked days are excluded upstream (charges_for_month), so
    # they usually have nothing left and never reach the loop below — count
    # them from the invoices themselves.
    skipped_keys = set()
    if customer is not None:
        if customer.id in billed_customers:
            skipped_keys.add(('user', customer.id))
    elif target_dog is not None:
        if target_dog.id in billed_dogs:
            skipped_keys.add(('dog', target_dog.id))
    else:
        for customer_id, billed_dog_id in active.values_list('customer_id', 'billed_dog_id'):
            skipped_keys.add(('user', customer_id) if customer_id is not None else ('dog', billed_dog_id))

    created = []
    for key, entry in customers.items():
        owner, billed_dog = entry['owner'], entry['dog']
        if (owner is not None and owner.id in billed_customers) or (billed_dog is not None and billed_dog.id in billed_dogs):
            skipped_keys.add(key)
            continue
        dogs = {d: v for d, v in entry['dogs'].items() if d.id not in billed_dogs}
        if not dogs:
            skipped_keys.add(key)
            continue
        try:
            with transaction.atomic():
                invoice = Invoice.objects.create(
                    customer=owner,
                    billed_dog=billed_dog,
                    period_year=year,
                    period_month=month,
                    status='DRAFT',
                    created_by=created_by,
                )
                invoice.total = _build_all_lines(invoice, dogs)
                invoice.save(update_fields=['total', 'updated_at'])
        except IntegrityError:
            # Someone else raised this customer's (or dog's) invoice for the
            # period while this run was working — the monthly cron and a
            # manager pressing Generate, say. The unique constraint kept it to
            # one; count ours as skipped and carry on with everybody else
            # rather than abandoning the run halfway.
            skipped_keys.add(key)
            continue
        push_draft_to_xero(invoice)
        created.append(invoice)
    return created, len(skipped_keys), manual


def _build_all_lines(invoice, dogs):
    """Create every line for ``{dog: charges}`` (see ``charges_for_month``);
    returns the total.

    One line per day, so the invoice reads as a diary of the dog's
    attendance: for each dog (by name) the days run in date order, which
    puts earlier months' unbilled extras first and this month's booked days
    and boarding nights after them. Each line carries its own date in
    ``attendance_dates`` — that is what ``_billed_ledger`` reads to make sure
    a date is never charged twice. A credit for a daycare day that a boarding
    night replaced sits straight after that night."""
    period_start = date_cls(invoice.period_year, invoice.period_month, 1)

    def earlier(day):
        """The month's name when ``day`` is before this invoice's period."""
        return _calendar.month_name[day.month] if day < period_start else None

    total = Decimal('0.00')
    for dog, charges in sorted(dogs.items(), key=lambda item: item[0].name.lower()):
        items = [(d, LINE_DAYCARE, owner_transport, earlier(d), None)
                 for d, owner_transport in charges.get('extra_daycare', [])]
        items += [(n, LINE_BOARDING, False, earlier(n), None) for n in charges.get('extra_boarding', [])]
        items += [(d, LINE_DAYCARE, owner_transport, None, None) for d, owner_transport in charges.get('daycare', [])]
        items += [(n, LINE_BOARDING, False, None, None) for n in charges.get('boarding', [])]
        items += [(d, LINE_CREDIT, False, None, (amount, label)) for d, amount, label in charges.get('credits', [])]
        # Same date: the night, then its credit ('boarding' < 'credit' < 'daycare').
        items.sort(key=lambda item: (item[0], item[1]))
        total += _build_day_lines(invoice, dog, items)
    return total


def _build_day_lines(invoice, dog, items):
    """Create one InvoiceLine per ``(date, kind, owner_transport, extra_month,
    credit)`` item for ``dog``; returns their total. ``extra_month`` names the
    month when the day is an earlier month's unbilled extra rather than one of
    this month's booked days.

    A daycare day where the owner handled both transport legs bills at the
    day rate minus the configurable owner-transport discount, and the line
    says so; other days bill at the full rate. Boarding nights bill at the
    per-night rate.

    A credit item ``(amount, invoice label)`` gives back a daycare day that
    was charged on an earlier invoice and that a boarding night on this one
    replaces. It is never more than the night it sits beside: if the night
    costs less than the day did (or the boarding price has not been set),
    the customer has already paid at least the night's price for that date
    and nothing further is taken off — this mechanism never produces a
    refund or a negative invoice, which Xero would refuse."""
    from website.models import ServicePricing

    discount = ServicePricing.load().owner_transport_discount
    day_rate, note = resolve_day_rate(dog, customer=invoice.customer)
    night_rate = get_boarding_rate(dog, customer=invoice.customer)
    total = Decimal('0.00')
    for day, kind, owner_transport, extra_month, credit in items:
        when = day.strftime('%a %d/%m/%Y')
        if kind == LINE_CREDIT:
            charged, label = credit
            rate = -min(Decimal(charged), Decimal(night_rate))
            if rate >= 0:
                continue
            description = (
                f"{CREDIT_PREFIX}{dog.name} — {when} (daycare day charged on your "
                f"{label} invoice; replaced by the boarding night)"
            )
        elif kind == LINE_BOARDING:
            rate = night_rate
            tail = f' (extra night in {extra_month})' if extra_month else ''
            description = f"Boarding — {dog.name} — night of {when}{tail}"
        else:
            discounted = owner_transport and discount > 0
            rate = max(day_rate - discount, Decimal('0.00')) if discounted else day_rate
            notes = [note]
            if extra_month:
                notes.insert(0, f'extra day in {extra_month}')
            if discounted:
                notes.append('owner drop-off & pick-up')
            description = f"Daycare — {dog.name} — {when} ({', '.join(notes)})"
        InvoiceLine.objects.create(
            invoice=invoice,
            dog=dog,
            description=description[:255],
            quantity=1,
            unit_price=rate,
            line_total=rate,
            attendance_dates=[day.isoformat()],
        )
        total += rate
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
    # A dog-name invoice's charges sit under the dog's owner (or None when it
    # has no client); only its own dog's charges belong on it. The invoice's
    # own lines are ignored when working out what is already billed.
    owner_key = invoice.billed_dog.owner if invoice.billed_dog is not None else invoice.customer
    dogs = charges_for_month(invoice.period_year, invoice.period_month, exclude_invoice=invoice).get(owner_key, {})
    if invoice.billed_dog is not None:
        dogs = {dog: c for dog, c in dogs.items() if dog.id == invoice.billed_dog_id}
    else:
        # Dogs raised on their own invoice for the period stay off the owner's.
        elsewhere = _dogs_billed_elsewhere(invoice.period_year, invoice.period_month, exclude=invoice)
        dogs = {dog: c for dog, c in dogs.items() if dog.id not in elsewhere}
    with transaction.atomic():
        invoice.lines.filter(is_adjustment=False).delete()
        invoice.total = _build_all_lines(invoice, dogs) + _adjustments_total(invoice)
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

    due_date = timezone.localdate() + timedelta(days=PAYMENT_TERMS_DAYS)
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
    due_date = due_date or invoice.due_date or timezone.localdate()
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
            due_date=timezone.localdate() + timedelta(days=PAYMENT_TERMS_DAYS),
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
    unpin it on the reconciliation screen.

    A contact found by **name alone is used for this invoice but never
    pinned**: two clients can share a name, and a pin would send every later
    invoice to whoever Xero happened to list first. It stays unpinned until
    someone confirms it on the reconciliation screen. (A same-name contact
    whose Xero email is a different address is refused outright —
    ``xero.XeroContactMismatch`` — and surfaces as the push error.)"""
    if invoice.customer is not None:
        profile = getattr(invoice.customer, 'profile', None)
        if profile is not None and profile.xero_contact_id:
            return profile.xero_contact_id
        contact_id, matched_by = xero.resolve_contact(invoice.customer)
        if matched_by == 'name':
            return contact_id
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
    payment_date = payment_date or timezone.localdate()

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
                idempotency_key=f'p4td-payment-{payment.id}',
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

    Sent invoices (SENT/PART_PAID): one voided in Xero is VOIDed here too —
    unless payments are recorded against it in the app, when it is left for a
    person and says so in ``xero_sync_error``; one whose total was amended in
    Xero after approval adopts the new total the same way a draft does. Then
    Xero payments are imported as PaymentRecords (deduped by
    ``xero_payment_id``) and, when Xero reports more paid than the ledger
    accounts for (credit notes, prepayments, overpayments), the difference is
    booked as a synthetic adjustment so the totals stay honest.

    Interrupted sends: ``send_invoice`` holds an invoice in SENDING while it
    talks to Xero. If the process was killed mid-send nothing else would ever
    move it on, so a row that has sat in SENDING for
    ``SENDING_STALE_MINUTES`` is settled from what Xero says — approved there
    becomes SENT, still a draft (or never raised) goes back to DRAFT to be
    sent again.

    The list of invoices is read up front, but the Xero calls take seconds,
    so each invoice is **re-read under a row lock** before anything is written
    to it. A staff member voiding or sending it meanwhile is seen, not
    overwritten from a stale copy. Pushes and follow-up Xero calls happen
    after that lock is released. Returns counts for logging.
    """
    counts = {
        'checked': 0, 'payments_imported': 0, 'paid': 0, 'approved': 0, 'voided': 0,
        'amended': 0, 'recovered': 0, 'needs_review': 0, 'errors': 0,
    }
    if not XeroConnection.load().is_connected:
        return counts

    now = timezone.now()
    stale_before = now - timedelta(minutes=SENDING_STALE_MINUTES)

    # A send that died before Xero was ever given the invoice: nothing to ask
    # Xero about, so it simply becomes a draft again.
    never_raised = Invoice.objects.filter(
        status='SENDING', xero_invoice_id='', updated_at__lt=stale_before,
    ).values_list('pk', flat=True)
    for pk in list(never_raised):
        counts['recovered'] += _release_stale_sending(pk, stale_before)

    pk_by_xero_id = dict(
        Invoice.objects
        .filter(Q(status__in=('DRAFT', 'SENT', 'PART_PAID'))
                | Q(status='SENDING', updated_at__lt=stale_before))
        .exclude(xero_invoice_id='')
        .values_list('xero_invoice_id', 'pk')
    )
    ids = list(pk_by_xero_id)

    for start in range(0, len(ids), XERO_FETCH_CHUNK):
        chunk = ids[start:start + XERO_FETCH_CHUNK]
        try:
            remote_invoices = xero.fetch_invoices(chunk)
        except xero.XeroError as exc:
            logger.error('Xero invoice sync failed: %s', exc)
            counts['errors'] += 1
            continue
        returned = set()
        for remote in remote_invoices:
            pk = pk_by_xero_id.get(remote.get('InvoiceID'))
            if pk is None:
                continue
            returned.add(remote.get('InvoiceID'))
            counts['checked'] += 1
            afterwards = []
            with transaction.atomic():
                invoice = _lock_invoice(pk)
                if invoice is not None:
                    _apply_remote_state(invoice, remote, now, stale_before, counts, afterwards)
            for action in afterwards:
                try:
                    action()
                except Exception:  # a failed push must not stop the sync
                    logger.exception('Follow-up after syncing invoice %s failed', pk)
        # Xero no longer knows an invoice a send was interrupted on.
        for xero_id in chunk:
            if xero_id not in returned:
                counts['recovered'] += _release_stale_sending(pk_by_xero_id[xero_id], stale_before)
    return counts


def _lock_invoice(pk):
    """The invoice re-read under a row lock (call inside a transaction), or
    None if it has gone. Ordered by pk on purpose: the model's default
    ordering joins the nullable customer, and PostgreSQL refuses FOR UPDATE
    across the nullable side of an outer join."""
    return Invoice.objects.select_for_update().filter(pk=pk).order_by('pk').first()


def _release_stale_sending(pk, stale_before):
    """Put an invoice stranded in SENDING back to DRAFT so it can be sent
    again. Re-checked under the row lock: a send that is merely slow (or has
    since finished) is left alone. Returns 1 when it was released."""
    with transaction.atomic():
        invoice = _lock_invoice(pk)
        if invoice is None or invoice.status != 'SENDING' or invoice.updated_at >= stale_before:
            return 0
        invoice.status = 'DRAFT'
        invoice.save(update_fields=['status', 'updated_at'])
    logger.warning('Invoice %s was stranded in SENDING; returned to DRAFT', pk)
    return 1


def _apply_remote_state(invoice, remote, now, stale_before, counts, afterwards):
    """Bring one freshly locked invoice into line with Xero's copy of it.

    Database writes only — anything that talks to Firebase or Xero is
    appended to ``afterwards`` and run once the lock is released."""
    remote_status = remote.get('Status', '')

    if invoice.status == 'SENDING':
        if invoice.updated_at >= stale_before:
            return  # a send is in flight; it will finish the job itself
        if remote_status in XERO_APPROVED_STATUSES:
            # Xero approved it, the process died before saying so here.
            _mark_sent_from_xero(invoice, remote, afterwards)
            # Whether Xero's email went out is unknown — sending it again
            # unasked could email the customer twice, so a person decides.
            if not invoice.xero_emailed_at:
                invoice.xero_sync_error = (
                    'Recovered after an interrupted send: the invoice is approved in Xero, '
                    'but the Xero email may not have gone out. Use "Push to Xero" to email it.')
                invoice.save(update_fields=['xero_sync_error', 'updated_at'])
            counts['recovered'] += 1
        elif remote_status in XERO_CANCELLED_STATUSES:
            invoice.status = 'VOID'
            invoice.xero_last_synced_at = now
            invoice.save(update_fields=['status', 'xero_last_synced_at', 'updated_at'])
            counts['voided'] += 1
            return
        else:
            invoice.status = 'DRAFT'
            invoice.xero_last_synced_at = now
            invoice.save(update_fields=['status', 'xero_last_synced_at', 'updated_at'])
            counts['recovered'] += 1
            return
    elif invoice.status == 'DRAFT':
        _learn_contact(invoice, remote)
        if remote_status in XERO_CANCELLED_STATUSES:
            invoice.status = 'VOID'
            invoice.xero_last_synced_at = now
            invoice.save(update_fields=['status', 'xero_last_synced_at', 'updated_at'])
            counts['voided'] += 1
            return
        if remote_status not in XERO_APPROVED_STATUSES:
            invoice.xero_last_synced_at = now
            invoice.save(update_fields=['xero_last_synced_at', 'updated_at'])
            return
        _mark_sent_from_xero(invoice, remote, afterwards)
        counts['approved'] += 1
    elif invoice.status in ('SENT', 'PART_PAID'):
        _learn_contact(invoice, remote)
        if remote_status in XERO_CANCELLED_STATUSES:
            if _void_from_xero(invoice, now):
                counts['voided'] += 1
            else:
                counts['needs_review'] += 1
            return
        if remote_status in XERO_APPROVED_STATUSES and _adopt_remote_total(invoice, remote):
            counts['amended'] += 1
    else:
        # Voided, paid or otherwise settled since the list was read.
        return

    was_paid = invoice.status == 'PAID'
    counts['payments_imported'] += _import_remote_payments(invoice, remote)
    refresh_payment_state(invoice)
    invoice.xero_last_synced_at = now
    invoice.save(update_fields=['xero_last_synced_at', 'updated_at'])
    if invoice.status == 'PAID' and not was_paid:
        counts['paid'] += 1
        afterwards.append(lambda: _notify_invoice_paid(invoice))


def _void_from_xero(invoice, now):
    """A sent invoice was voided (or deleted) in Xero: void it here, so the
    customer stops seeing it as owed, stops being reminded, and its days can
    be invoiced again. Returns True when it was voided.

    Not when payments are recorded against it here — voiding would strand
    money on a dead invoice (the app's own Void asks for confirmation for the
    same reason). It is left as it is with a note for a payment manager."""
    collected = invoice.payments.aggregate(total=Sum('amount'))['total'] or Decimal('0.00')
    invoice.xero_last_synced_at = now
    if collected > 0:
        invoice.xero_sync_error = (
            f'This invoice was voided in Xero, but £{collected:.2f} of payments are recorded '
            'against it here. Check the payments, then void it in the app.')
        invoice.save(update_fields=['xero_sync_error', 'xero_last_synced_at', 'updated_at'])
        return False
    invoice.status = 'VOID'
    invoice.xero_sync_error = ''
    invoice.save(update_fields=['status', 'xero_sync_error', 'xero_last_synced_at', 'updated_at'])
    return True


def _adopt_remote_total(invoice, remote):
    """Take Xero's total when it differs from ours, booking the difference as
    an "Amended in Xero" adjustment line so the lines still add up. Returns
    True when the total changed. A response with no ``Total`` changes nothing."""
    if remote.get('Total') is None:
        return False
    remote_total = Decimal(str(remote['Total'])).quantize(Decimal('0.01'))
    if remote_total == invoice.total:
        return False
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
    invoice.save(update_fields=['total', 'updated_at'])
    return True


def _mark_sent_from_xero(invoice, remote, afterwards=None):
    """A draft approved inside Xero becomes SENT here. Xero's copy is the one
    the customer received, so its total, due date and number win.

    The online-payment lookup and the owner's push are queued on
    ``afterwards`` when one is given (the sync runs them once it has let go
    of the row lock), otherwise done straight away."""
    _adopt_remote_total(invoice, remote)
    invoice.status = 'SENT'
    invoice.sent_at = timezone.now()
    invoice.due_date = _parse_xero_date(remote.get('DueDate')) or (
        timezone.localdate() + timedelta(days=PAYMENT_TERMS_DAYS))
    if remote.get('InvoiceNumber'):
        invoice.xero_invoice_number = remote['InvoiceNumber']
    invoice.xero_sync_error = ''
    invoice.save(update_fields=[
        'status', 'sent_at', 'due_date', 'total', 'xero_invoice_number', 'xero_sync_error', 'updated_at'])

    def follow_up():
        _backfill_online_url(invoice)
        if invoice.customer is not None:
            send_push_notification(
                invoice.customer,
                'New invoice',
                f'Your daycare invoice for {invoice.period_label} is ready: £{invoice.total}.',
                data={'type': 'invoice', 'id': str(invoice.id), 'click_action': 'FLUTTER_NOTIFICATION_CLICK'},
            )

    if afterwards is None:
        follow_up()
    else:
        afterwards.append(follow_up)


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
                                 or timezone.localdate()),
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
                'payment_date': timezone.localdate(),
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
