"""Ingestion of DfT Street Manager open data into `RoadworkIssue`.

Street Manager has no polling API for open-data consumers — it pushes permit and
activity events to a subscriber-hosted HTTPS endpoint via AWS SNS. See
https://department-for-transport-streetmanager.github.io/street-manager-docs/open-data/

Going live needs three things outside this file:

1. The organisation registered at
   https://www.manage-roadworks.service.gov.uk/open-data-onboarding, supplying
   this endpoint's public URL.
2. `STREET_MANAGER_TOPIC_ARNS` set, so messages from topics we did not subscribe
   to are rejected even if AWS genuinely sent them.
3. An SNS subscription filter policy on `highway_authority`, because the topic
   carries the whole country's street works. Without a filter this endpoint
   receives every permit event in Great Britain; with one it receives only the
   authorities the routes actually cross.
"""

from __future__ import annotations

import logging
from datetime import datetime

from django.conf import settings
from django.db import transaction

from .roadworks import bng_to_wgs84, parse_wkt_centroid, severity_for

logger = logging.getLogger(__name__)

# Permit/activity states that mean "this is not happening (any more)".
_DEAD_STATES = {
    'cancelled', 'refused', 'revoked', 'closed', 'completed',
    'permit_cancelled', 'permit_refused', 'permit_revoked', 'work_stopped',
}


def topic_arns() -> list[str]:
    configured = getattr(settings, 'STREET_MANAGER_TOPIC_ARNS', '') or ''
    if isinstance(configured, (list, tuple)):
        return [str(a).strip() for a in configured if str(a).strip()]
    return [a.strip() for a in configured.split(',') if a.strip()]


def _parse_date(value):
    """Street Manager sends ISO 8601 dates and datetimes; we only need the date."""
    if not value:
        return None
    text = str(value).strip()
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    try:
        return datetime.fromisoformat(text).date()
    except ValueError:
        try:
            return datetime.strptime(text[:10], '%Y-%m-%d').date()
        except ValueError:
            return None


def _first(data: dict, *keys):
    for key in keys:
        value = data.get(key)
        if value not in (None, ''):
            return value
    return None


def issue_fields_from_payload(data: dict) -> dict | None:
    """Map one Street Manager `object_data` record onto `RoadworkIssue` fields.

    Returns None when the record can't be placed on the map or in time — an
    issue with no location can't be matched to a route, so storing it would only
    add noise.
    """
    ref = _first(data, 'permit_reference_number', 'work_reference_number', 'activity_reference_number')
    if not ref:
        return None

    start = _parse_date(_first(
        data, 'actual_start_date_time', 'proposed_start_date', 'start_date', 'actual_start_date'))
    end = _parse_date(_first(
        data, 'actual_end_date_time', 'proposed_end_date', 'end_date', 'actual_end_date'))
    if not start or not end:
        return None
    if end < start:
        start, end = end, start

    coords = parse_wkt_centroid(_first(data, 'work_area_wkt', 'activity_location_coordinates', 'wkt') or '')
    if not coords:
        return None
    latitude, longitude = bng_to_wgs84(coords[0], coords[1])

    traffic_management = _first(data, 'traffic_management_type', 'traffic_management_type_string') or ''

    state = str(_first(data, 'permit_status', 'work_status', 'activity_status') or '').strip().lower()

    return {
        'external_ref': str(ref)[:100],
        'description': str(_first(data, 'description_of_work', 'activity_name', 'work_category') or '')[:2000],
        'street': str(_first(data, 'street_name', 'usrn_street_name') or '')[:255],
        'town': str(_first(data, 'town', 'area_name') or '')[:255],
        'highway_authority': str(_first(data, 'highway_authority', 'highway_authority_swa_code') or '')[:255],
        'latitude': latitude,
        'longitude': longitude,
        'start_date': start,
        'end_date': end,
        'traffic_management': str(traffic_management)[:100],
        'severity': severity_for(str(traffic_management)),
        'is_cancelled': state in _DEAD_STATES,
    }


@transaction.atomic
def ingest_event(event: dict) -> str:
    """Apply one decoded Street Manager SNS event. Returns what it did.

    Idempotent: replays of the same permit reference update the existing row
    rather than piling up duplicates, which matters because SNS guarantees
    at-least-once delivery, not exactly-once.
    """
    from .models import RoadworkIssue

    data = event.get('object_data')
    if not isinstance(data, dict):
        return 'ignored:no-object-data'

    fields = issue_fields_from_payload(data)
    if not fields:
        return 'ignored:unusable'

    ref = fields.pop('external_ref')
    issue, created = RoadworkIssue.objects.update_or_create(
        source='STREET_MANAGER',
        external_ref=ref,
        defaults={**fields, 'raw_payload': event},
    )
    return 'created' if created else 'updated'
