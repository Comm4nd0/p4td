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

and nobody attends on a CLOSED closure day.

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


class ScheduleIndex:
    """Bulk-loads everything needed to answer attendance and capacity
    questions for every day in [start, end] with a fixed number of queries."""

    def __init__(self, start, end):
        from .models import (
            BoardingRequest, ClosureDay, DailyDogAssignment, DateChangeRequest,
            DaycareSettings, Dog,
        )
        self.start = start
        self.end = end

        self.closures = {
            c.date: c for c in ClosureDay.objects.filter(date__range=(start, end))
        }

        self.cancels_by_date = defaultdict(set)
        cancel_rows = DateChangeRequest.objects.filter(
            status='APPROVED', original_date__range=(start, end),
        ).filter(
            Q(request_type='CANCEL') | Q(request_type='CHANGE')
        ).values_list('original_date', 'dog_id')
        for day, dog_id in cancel_rows:
            self.cancels_by_date[day].add(dog_id)

        self.adds_by_date = defaultdict(set)
        add_rows = DateChangeRequest.objects.filter(
            status='APPROVED', new_date__range=(start, end),
        ).filter(
            Q(request_type='ADD_DAY') | Q(request_type='CHANGE')
        ).values_list('new_date', 'dog_id')
        for day, dog_id in add_rows:
            self.adds_by_date[day].add(dog_id)

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
