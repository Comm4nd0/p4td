"""Shared schedule projection and capacity helpers.

The staff roster, the owner calendar endpoint and capacity enforcement all
need to answer "which dogs attend on date X?". The rules mirror
``DailyDogAssignmentViewSet.unassigned_dogs``:

    attending = (dogs whose daycare_days include the weekday
                 + approved ADD_DAY / CHANGE-to requests for the date
                 + dogs with a non-REMOVED assignment row for the date
                 + approved boarding spanning the date)
                - approved CANCEL / CHANGE-away requests for the date
                - dogs staff explicitly REMOVED for the date

When the same (dog, date) has both approved cancellations and approved
additions, the most recently approved request wins — a dog can be taken off
a day and later added back (or added and then cancelled again); no single
request permanently vetoes the date. See ``effective_change_actions``.

Nobody attends on a CLOSED closure day.

Note: fortnightly dogs are intentionally treated like weekly dogs — the rest
of the system (roster materialization, unassigned_dogs) does the same.
"""
from collections import defaultdict
from datetime import timedelta

from django.db.models import Q
from django.utils import timezone


def daterange(start, end):
    """Yield each date from start to end inclusive."""
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)


def effective_change_actions(start, end, dog_ids=None):
    """Resolve approved date-change requests into per-day overlays where the
    most recently approved request wins for each (dog, date).

    Returns ``(adds_by_date, cancels_by_date)`` — dicts of date -> set of dog
    ids. A dog appears in at most one of the two sets for a given date: in
    ``adds_by_date`` when its latest approved action for the date is an
    ADD_DAY / CHANGE-to, in ``cancels_by_date`` when it is a CANCEL /
    CHANGE-away. Recency is ``approved_at`` (falling back to ``created_at``
    for rows approved before approved_at existed), with id as tie-break.
    """
    from .models import DateChangeRequest

    qs = DateChangeRequest.objects.filter(status='APPROVED').filter(
        Q(request_type__in=('CANCEL', 'CHANGE'), original_date__range=(start, end))
        | Q(request_type__in=('ADD_DAY', 'CHANGE'), new_date__range=(start, end))
    )
    if dog_ids is not None:
        qs = qs.filter(dog_id__in=dog_ids)

    latest = {}  # (date, dog_id) -> (sort_key, is_add)
    rows = qs.values_list(
        'id', 'dog_id', 'request_type', 'original_date', 'new_date',
        'approved_at', 'created_at',
    )
    for req_id, dog_id, request_type, original_date, new_date, approved_at, created_at in rows:
        sort_key = (approved_at or created_at, req_id)
        # A CHANGE acts on two dates: a cancel of original_date plus an add of
        # new_date (never the same date — the serializer forbids it).
        actions = []
        if request_type in ('CANCEL', 'CHANGE'):
            actions.append((original_date, False))
        if request_type in ('ADD_DAY', 'CHANGE'):
            actions.append((new_date, True))
        for day, is_add in actions:
            if day is None or not (start <= day <= end):
                continue
            key = (day, dog_id)
            if key not in latest or sort_key > latest[key][0]:
                latest[key] = (sort_key, is_add)

    adds_by_date = defaultdict(set)
    cancels_by_date = defaultdict(set)
    for (day, dog_id), (_, is_add) in latest.items():
        (adds_by_date if is_add else cancels_by_date)[day].add(dog_id)
    return adds_by_date, cancels_by_date


class ScheduleIndex:
    """Bulk-loads everything needed to answer attendance and capacity
    questions for every day in [start, end] with a fixed number of queries."""

    def __init__(self, start, end):
        from .models import (
            BoardingRequest, ClosureDay, DailyDogAssignment, DaycareSettings, Dog,
        )
        self.start = start
        self.end = end

        self.closures = {
            c.date: c for c in ClosureDay.objects.filter(date__range=(start, end))
        }

        self.adds_by_date, self.cancels_by_date = effective_change_actions(start, end)

        self.weekday_dogs = defaultdict(set)
        for dog_id, days in Dog.objects.values_list('id', 'daycare_days'):
            for day_number in (days or []):
                self.weekday_dogs[day_number].add(dog_id)

        self.active_assignments_by_date = defaultdict(set)
        self.removed_assignments_by_date = defaultdict(set)
        assignment_rows = DailyDogAssignment.objects.filter(
            date__range=(start, end),
        ).values_list('date', 'dog_id', 'status')
        for day, dog_id, status in assignment_rows:
            if status == 'REMOVED':
                self.removed_assignments_by_date[day].add(dog_id)
            else:
                self.active_assignments_by_date[day].add(dog_id)

        self.boarding_by_date = defaultdict(set)
        boarding_rows = BoardingRequest.objects.filter(
            status='APPROVED', start_date__lte=end, end_date__gte=start,
        ).values_list('dogs__id', 'start_date', 'end_date')
        for dog_id, b_start, b_end in boarding_rows:
            if dog_id is None:
                continue
            for day in daterange(max(b_start, start), min(b_end, end)):
                self.boarding_by_date[day].add(dog_id)

        self.default_capacity = DaycareSettings.load().default_daily_capacity or None

    def closure(self, day):
        return self.closures.get(day)

    def boarding_dog_ids(self, day):
        return self.boarding_by_date.get(day, set())

    def attending_dog_ids(self, day):
        closure = self.closure(day)
        if closure and closure.closure_type == 'CLOSED':
            return set()
        attending = (
            self.weekday_dogs.get(day.isoweekday(), set())
            | self.adds_by_date.get(day, set())
        ) - self.cancels_by_date.get(day, set())
        attending |= self.active_assignments_by_date.get(day, set())
        attending -= self.removed_assignments_by_date.get(day, set())
        attending |= self.boarding_by_date.get(day, set())
        return attending

    def capacity_for(self, day):
        """Effective capacity as an int, or None when unlimited."""
        closure = self.closure(day)
        if closure:
            if closure.closure_type == 'CLOSED':
                return 0
            if closure.capacity_override:
                return closure.capacity_override
        return self.default_capacity

    def capacity_info(self, day):
        booked = len(self.attending_dog_ids(day))
        capacity = self.capacity_for(day)
        if capacity is None:
            return {'capacity': None, 'booked': booked, 'is_full': False, 'spots_left': None}
        return {
            'capacity': capacity,
            'booked': booked,
            'is_full': booked >= capacity,
            'spots_left': max(0, capacity - booked),
        }


def capacity_check(target_date, dog_id=None):
    """Return (fits, info): whether one more dog fits on ``target_date``.

    A dog already attending that day always fits (e.g. approving a CHANGE to a
    date the dog is already on)."""
    index = ScheduleIndex(target_date, target_date)
    info = index.capacity_info(target_date)
    if dog_id is not None and dog_id in index.attending_dog_ids(target_date):
        return True, info
    if info['capacity'] is None:
        return True, info
    return info['booked'] < info['capacity'], info


def process_waitlist_for_date(target_date):
    """Notify the longest-waiting owners when spots are free on ``target_date``.

    Called after anything that can free a spot (cancellation approved, dog
    removed from a day, closure lifted). Notified entries flip to NOTIFIED so
    they are not pinged twice; the owner still requests the day through the
    normal flow. Returns the number of entries notified.
    """
    from .models import WaitlistEntry
    from .notifications import send_push_notification

    index = ScheduleIndex(target_date, target_date)
    closure = index.closure(target_date)
    if closure and closure.closure_type == 'CLOSED':
        return 0

    attending = index.attending_dog_ids(target_date)
    info = index.capacity_info(target_date)
    if info['capacity'] is None:
        spots = None  # unlimited — notify everyone still waiting
    else:
        spots = info['spots_left']
        if spots <= 0:
            return 0

    entries = (
        WaitlistEntry.objects
        .filter(date=target_date, status='WAITING')
        .exclude(dog_id__in=attending)
        .select_related('dog', 'dog__owner', 'requested_by')
        .order_by('created_at')
    )
    if spots is not None:
        entries = entries[:spots]

    notified = 0
    for entry in entries:
        body = (
            f"A daycare spot on {target_date.strftime('%a %d %b')} has opened up. "
            f"Request the day for {entry.dog.name} in the app before it's gone!"
        )
        data = {
            'type': 'waitlist_spot',
            'date': target_date.isoformat(),
            'dog_id': str(entry.dog_id),
        }
        recipients = {entry.requested_by, entry.dog.owner}
        for user in recipients:
            if user is None:
                continue
            try:
                send_push_notification(user, 'A spot opened up!', body, data, category='bookings')
            except Exception as exc:
                print(f"Failed to send waitlist notification: {exc}")
        entry.status = 'NOTIFIED'
        entry.notified_at = timezone.now()
        entry.save(update_fields=['status', 'notified_at'])
        notified += 1
    return notified


# =============================================================================
# BOARDING → DAYCARE ATTENDANCE
# =============================================================================
#
# A boarding dog is here all week, so it is in daycare every weekday of its
# stay — arrival day and going-home day included. The dog isn't out on a
# driver's route on those days (the boarding carer already has it, and the
# transport legs in DailyDogAssignment.needs_staff_pickup / _dropoff only exist
# on the edges of the stay), so its attendance is booked under the business's
# own "P4TD" account rather than a driver.
#
# This is billing-neutral by construction: billing.attendance_for_month skips
# any (dog, date) inside an approved stay, so these rows are never charged as
# daycare on top of the boarding nights. They exist so the dog shows up on the
# day's roster, in headcount and capacity, and on the day board — instead of
# living only in the "boarding" list off to one side.
#
# The arrival day is the exception. The dog is still at home that morning, so
# somebody has to collect it (DailyDogAssignment.needs_staff_pickup says the
# same: the home → daycare leg exists on the first day of a stay). Booking it
# to the house account would hide that pickup from every driver's list, so an
# arrival that lands on a weekday is left UNASSIGNED instead and surfaces in
# ``unassigned_dogs`` for a driver to claim. Dogs whose owner normally brings
# them in (``Dog.owner_brings_default``) need no driver and go straight to the
# house account, as does a weekend arrival — daycare doesn't run then, and by
# the stay's first weekday the dog is already with the boarding carer.

# The business's own pseudo-staff account, matched case-insensitively.
HOUSE_STAFF_USERNAME = 'p4td'

# Boarding covers weekends; daycare doesn't. Mon–Fri only.
DAYCARE_WEEKDAYS = (1, 2, 3, 4, 5)


def house_staff_account():
    """The 'P4TD' pseudo-staff account, or None if it doesn't exist.

    Matched on username first, then first name, so it works whichever way the
    account was set up. Callers treat None as "leave attendance alone" rather
    than inventing an account or silently assigning a real staff member.
    """
    from django.contrib.auth.models import User

    staff = User.objects.filter(is_staff=True)
    return (
        staff.filter(username__iexact=HOUSE_STAFF_USERNAME).first()
        or staff.filter(first_name__iexact=HOUSE_STAFF_USERNAME).first()
    )


def boarding_arrival_dog_ids(dog_ids, arrival_date):
    """Of ``dog_ids``, the ones whose stay genuinely begins on ``arrival_date``.

    These are the dogs still at home that morning, so a driver has to collect
    them. Two things disqualify a date:

      * it isn't a weekday — daycare doesn't run, and by the stay's first
        weekday the dog is already with the boarding carer;
      * another approved stay already covered the day before. Back-to-back
        bookings are one stay (the same rule ``needs_staff_pickup`` uses); the
        dog isn't arriving, it is simply carrying on.
    """
    from .models import BoardingRequest

    dog_ids = set(dog_ids)
    if not dog_ids or arrival_date.isoweekday() not in DAYCARE_WEEKDAYS:
        return set()
    yesterday = arrival_date - timedelta(days=1)
    already_here = set(
        BoardingRequest.objects
        .filter(
            status='APPROVED', dogs__id__in=dog_ids,
            start_date__lte=yesterday, end_date__gte=yesterday,
        )
        .values_list('dogs__id', flat=True)
    )
    return dog_ids - already_here


def boarding_daycare_dates(start, end):
    """The days of a stay the dog should be booked into daycare on.

    Every date from arrival to departure inclusive that falls Mon–Fri and
    isn't a CLOSED closure day.
    """
    from .models import ClosureDay

    days = [d for d in daterange(start, end) if d.isoweekday() in DAYCARE_WEEKDAYS]
    if not days:
        return []
    closed = set(
        ClosureDay.objects
        .filter(date__in=days, closure_type='CLOSED')
        .values_list('date', flat=True)
    )
    return [d for d in days if d not in closed]


def sync_boarding_daycare_assignments(boarding_request):
    """Book an approved stay's dogs into daycare for every weekday it covers.

    Creates the missing ``DailyDogAssignment`` rows against the house account
    and moves rows that already exist (the dog's normal daycare day, with its
    normal driver) onto it too — that is what "assigned to P4TD throughout the
    stay" means for a dog whose stay overlaps its own daycare days.

    A weekday arrival is the exception: the dog is at home that morning and
    needs collecting, so the day is left UNASSIGNED (no staff member) for a
    driver to pick up from the unassigned list, and a row that already has a
    real driver on it keeps them. Dogs the owner normally brings in
    themselves are booked to the house account as usual — nobody has to
    fetch them. See the section comment above.

    Left alone:
      * REMOVED rows — staff have explicitly said the dog isn't attending.
      * anything outside Mon–Fri, and CLOSED days.

    Called from the deliberate moments — approval, and a date/dog change on an
    approved stay. The day-load path is :func:`materialize_boarding_for_date`,
    which only fills gaps so it can never undo a later manual reassignment.

    Returns the number of rows created or changed. A no-op when the stay isn't
    APPROVED, or when there is no house account to assign to.
    """
    from .models import DailyDogAssignment, Dog

    if boarding_request.status != 'APPROVED':
        return 0
    house = house_staff_account()
    if house is None:
        return 0

    dates = boarding_daycare_dates(boarding_request.start_date, boarding_request.end_date)
    if not dates:
        return 0

    dog_ids = list(boarding_request.dogs.values_list('id', flat=True))
    if not dog_ids:
        return 0

    arrival = boarding_request.start_date
    arriving = boarding_arrival_dog_ids(dog_ids, arrival)
    brings_default = dict(
        Dog.objects.filter(id__in=dog_ids).values_list('id', 'owner_brings_default')
    )

    existing = {
        (row.dog_id, row.date): row
        for row in DailyDogAssignment.objects.filter(dog_id__in=dog_ids, date__in=dates)
    }

    def needs_collecting(dog_id, day, row):
        """True when a driver still has to fetch this dog from home that day."""
        if day != arrival or dog_id not in arriving:
            return False
        # A per-date override on an existing row beats the dog's default.
        if row is not None and row.owner_brings is not None:
            return not row.owner_brings
        return not brings_default.get(dog_id, False)

    touched = 0
    to_create = []
    for dog_id in dog_ids:
        for day in dates:
            row = existing.get((dog_id, day))
            collect = needs_collecting(dog_id, day, row)
            if row is None:
                to_create.append(DailyDogAssignment(
                    dog_id=dog_id,
                    staff_member=None if collect else house,
                    date=day,
                    status='UNASSIGNED' if collect else 'ASSIGNED',
                    from_boarding=True,
                ))
                touched += 1
                continue
            if row.status == 'REMOVED':
                continue
            if collect:
                # Whoever already has the arrival day keeps it — that driver
                # collects the dog, and a day already waiting for one is
                # where we want it. Only the house account is stood down,
                # because it never drives.
                if row.staff_member_id != house.id:
                    continue
                # Written through the queryset rather than save(): the
                # post_save signal on a status change pushes "<dog> is now
                # Unassigned" to the owner, and who drives the van is not
                # something they should be told about. auto_now doesn't fire
                # on update(), so stamp updated_at by hand.
                DailyDogAssignment.objects.filter(pk=row.pk).update(
                    staff_member=None,
                    status='UNASSIGNED',
                    from_boarding=True,
                    updated_at=timezone.now(),
                )
                touched += 1
                continue
            if row.staff_member_id == house.id and row.status == 'ASSIGNED' and row.from_boarding:
                continue
            row.staff_member = house
            row.status = 'ASSIGNED'
            row.from_boarding = True
            row.save(update_fields=['staff_member', 'status', 'from_boarding', 'updated_at'])
            touched += 1

    if to_create:
        DailyDogAssignment.objects.bulk_create(to_create, ignore_conflicts=True)
    return touched


def clear_boarding_daycare_assignments(boarding_request, dates=None):
    """Undo :func:`sync_boarding_daycare_assignments` for a stay that is no
    longer happening (cancelled, denied, re-opened, or its dates moved).

    Only rows flagged ``from_boarding`` are removed, so attendance staff
    entered by hand survives. Days still covered by another approved stay for
    the same dog are kept — back-to-back bookings shouldn't cancel each other
    out. Anything that was a normal daycare day is re-created from the weekday
    roster the next time that day is loaded.

    ``dates`` narrows the clear-out to specific days — used when a stay's dates
    are moved, so the days it still covers keep their attendance (and any
    picked-up/dropped-off progress on them) instead of being churned.

    Returns the number of rows deleted.
    """
    from .models import BoardingRequest, DailyDogAssignment

    if dates is None:
        dates = boarding_daycare_dates(boarding_request.start_date, boarding_request.end_date)
    dates = list(dates)
    if not dates:
        return 0
    dog_ids = list(boarding_request.dogs.values_list('id', flat=True))
    if not dog_ids:
        return 0

    still_boarding = set()
    other_stays = (
        BoardingRequest.objects
        .filter(
            status='APPROVED',
            dogs__id__in=dog_ids,
            start_date__lte=max(dates),
            end_date__gte=min(dates),
        )
        .exclude(pk=boarding_request.pk)
        .values_list('dogs__id', 'start_date', 'end_date')
    )
    for dog_id, start, end in other_stays:
        if dog_id is None:
            continue
        for day in dates:
            if start <= day <= end:
                still_boarding.add((dog_id, day))

    rows = DailyDogAssignment.objects.filter(
        dog_id__in=dog_ids, date__in=dates, from_boarding=True,
    )
    doomed = [row.id for row in rows if (row.dog_id, row.date) not in still_boarding]
    if not doomed:
        return 0
    deleted, _ = DailyDogAssignment.objects.filter(id__in=doomed).delete()
    return deleted


def materialize_boarding_for_date(target_date):
    """Fill in missing daycare attendance for every dog boarding on
    ``target_date``.

    The lazy counterpart to :func:`sync_boarding_daycare_assignments`, used
    when a day is loaded: it catches stays approved before this existed, and
    dogs added to a stay afterwards. Scoped to the one date and never
    re-points an existing row, so a staff member's manual reassignment for the
    day stands. Dogs arriving today that somebody has to collect are created
    UNASSIGNED rather than booked to the house account, exactly as at approval
    time.
    """
    from .models import BoardingRequest, DailyDogAssignment, Dog

    if target_date.isoweekday() not in DAYCARE_WEEKDAYS:
        return 0
    if not boarding_daycare_dates(target_date, target_date):
        return 0  # closure day
    house = house_staff_account()
    if house is None:
        return 0

    dog_ids = set(
        BoardingRequest.objects
        .filter(status='APPROVED', start_date__lte=target_date, end_date__gte=target_date)
        .values_list('dogs__id', flat=True)
    )
    dog_ids.discard(None)
    if not dog_ids:
        return 0

    already = set(
        DailyDogAssignment.objects
        .filter(date=target_date, dog_id__in=dog_ids)
        .values_list('dog_id', flat=True)
    )
    missing = dog_ids - already
    if not missing:
        return 0

    arriving = boarding_arrival_dog_ids(missing, target_date)
    brings_default = dict(
        Dog.objects.filter(id__in=missing).values_list('id', 'owner_brings_default')
    )
    to_create = []
    for dog_id in missing:
        collect = dog_id in arriving and not brings_default.get(dog_id, False)
        to_create.append(DailyDogAssignment(
            dog_id=dog_id,
            staff_member=None if collect else house,
            date=target_date,
            status='UNASSIGNED' if collect else 'ASSIGNED',
            from_boarding=True,
        ))
    if not to_create:
        return 0
    DailyDogAssignment.objects.bulk_create(to_create, ignore_conflicts=True)
    return len(to_create)
