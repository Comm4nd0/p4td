"""The owner's calendar feed: their dogs' booked days as an iCal subscription.

An owner subscribes once in Google, Apple or Outlook Calendar and that app
re-fetches the feed by itself. Calendar apps can't log in, so
``calendar-feed/<token>.ics`` is public and the token is the only credential:
it is separate from the login token, revocable from the app, and the feed
carries dog names and dates only — never an address or access instructions.

Days come from ``ScheduleIndex``, the same answer ``dogs/calendar/`` gives.
All-day events only: a dog's day has no reliable clock time. A daycare day is
one event per dog, a boarding stay one multi-day event per dog.

Hand-written rather than a dependency because all-day events need no time
zones or recurrence, which is all an iCal library would be earning its keep on.
"""
from datetime import timedelta

from django.db.models import Q
from django.http import Http404, HttpResponse
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_safe
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

from .models import BoardingRequest, CalendarFeed, Dog
from .scheduling import ScheduleIndex, daterange

DAYS_BACK = 30
DAYS_AHEAD = 183
REFRESH_INTERVAL = 'PT6H'


def _escape(text):
    return (
        text.replace('\\', '\\\\').replace(';', '\\;').replace(',', '\\,')
        .replace('\r\n', '\\n').replace('\n', '\\n').replace('\r', '\\n')
    )


def _fold(line):
    """Wrap at 75 octets (RFC 5545 3.1), never inside a multi-byte character."""
    lines, current, size = [], '', 0
    for char in line:
        width = len(char.encode('utf-8'))
        if size + width > 75:
            lines.append(current)
            current, size = ' ', 1
        current += char
        size += width
    lines.append(current)
    return '\r\n'.join(lines)


def feed_events(user, today):
    """(uid, summary, first day, last day) for the user's dogs, by date."""
    dogs = list(
        Dog.objects.filter(Q(owner=user) | Q(additional_owners=user))
        .distinct().values('id', 'name', 'daycare_days')
    )
    if not dogs:
        return []
    names = {dog['id']: dog['name'] for dog in dogs}
    regular_days = {dog['id']: set(dog['daycare_days'] or []) for dog in dogs}
    start = today - timedelta(days=DAYS_BACK)
    end = today + timedelta(days=DAYS_AHEAD)

    events = []
    stays = BoardingRequest.objects.filter(
        status='APPROVED', dogs__id__in=names,
        start_date__lte=end, end_date__gte=start,
    ).values_list('id', 'dogs__id', 'start_date', 'end_date')
    for stay_id, dog_id, first, last in stays:
        if dog_id not in names:
            continue
        nights = (last - first).days
        length = f' ({nights} night{"" if nights == 1 else "s"})' if nights else ''
        events.append((
            f'boarding-{stay_id}-{dog_id}@p4td',
            f'{names[dog_id]} – Boarding{length}',
            first, last,
        ))

    index = ScheduleIndex(start, end)
    for day in daterange(start, end):
        boarding = index.boarding_dog_ids(day)
        for dog_id in sorted(names.keys() & index.attending_dog_ids(day)):
            if dog_id in boarding:
                continue  # Part of the stay's own event.
            extra = day.isoweekday() not in regular_days[dog_id]
            events.append((
                f'daycare-{dog_id}-{day.isoformat()}@p4td',
                f'{names[dog_id]} – Daycare{" (extra day)" if extra else ""}',
                day, day,
            ))
    return sorted(events, key=lambda event: (event[2], event[1]))


def render_feed(user, today):
    stamp = timezone.now().strftime('%Y%m%dT%H%M%SZ')
    lines = [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'PRODID:-//Paws 4 Thought Dogs//Booking calendar//EN',
        'CALSCALE:GREGORIAN',
        'METHOD:PUBLISH',
        'X-WR-CALNAME:Paws 4 Thought Dogs',
        f'REFRESH-INTERVAL;VALUE=DURATION:{REFRESH_INTERVAL}',
        f'X-PUBLISHED-TTL:{REFRESH_INTERVAL}',
    ]
    for uid, summary, first, last in feed_events(user, today):
        lines += [
            'BEGIN:VEVENT',
            f'UID:{uid}',
            f'DTSTAMP:{stamp}',
            f'DTSTART;VALUE=DATE:{first.strftime("%Y%m%d")}',
            # An all-day event's end is exclusive: the day after the last one.
            f'DTEND;VALUE=DATE:{(last + timedelta(days=1)).strftime("%Y%m%d")}',
            f'SUMMARY:{_escape(summary)}',
            # Shown free, so a day at daycare doesn't block the owner's own diary.
            'TRANSP:TRANSPARENT',
            'END:VEVENT',
        ]
    lines.append('END:VCALENDAR')
    return ''.join(_fold(line) + '\r\n' for line in lines)


@require_safe
def calendar_feed_ics(request, token):
    """The feed itself. A plain Django view, not DRF: calendar apps send
    ``Accept: text/calendar``, which DRF's content negotiation answers with 406.
    """
    feed = CalendarFeed.objects.select_related('user').filter(
        token=token, user__is_active=True,
    ).first()
    if feed is None:
        raise Http404
    response = HttpResponse(
        render_feed(feed.user, timezone.localdate()),
        content_type='text/calendar; charset=utf-8',
    )
    response['Cache-Control'] = 'private, max-age=900'
    return response


def _link_payload(request, feed):
    if feed is None:
        return {'url': None, 'webcal_url': None}
    url = request.build_absolute_uri(reverse('calendar-feed-ics', args=[feed.token]))
    return {'url': url, 'webcal_url': 'webcal://' + url.split('://', 1)[1]}


@api_view(['GET', 'POST', 'DELETE'])
@permission_classes([IsAuthenticated])
def calendar_feed_link(request):
    """The signed-in user's feed link: GET reads it (null when they have none),
    POST makes it or returns the existing one, DELETE kills it. Posting again
    after a delete issues a new token, which is how a shared link is replaced.
    """
    if request.method == 'DELETE':
        CalendarFeed.objects.filter(user=request.user).delete()
        return Response(status=204)
    if request.method == 'POST':
        feed, _ = CalendarFeed.objects.get_or_create(user=request.user)
    else:
        feed = CalendarFeed.objects.filter(user=request.user).first()
    return Response(_link_payload(request, feed))
