"""Roadwork ingestion and route matching.

Two separate jobs live here:

* Turning an external feed's records into `RoadworkIssue` rows — including the
  British National Grid to WGS84 projection that DfT Street Manager data needs.
* Working out which staff member's route a given issue actually disrupts, by
  proximity to the pickup addresses already geocoded onto each `Dog`.

The matching is deliberately recomputed per request rather than cached against
the assignment rows: dogs get moved between drivers on the day board all the
time, and a stale "this route is affected" flag is worse than none.
"""

from __future__ import annotations

import logging
import math
import re
from datetime import date

from django.conf import settings

logger = logging.getLogger(__name__)

# How close a dog's pickup address has to be to a roadwork for that route to be
# considered affected. 400m is roughly "the same handful of streets" — tight
# enough that a closure two estates over doesn't cry wolf, loose enough to catch
# the road you'd actually turn down.
DEFAULT_MATCH_RADIUS_M = 400.0


def match_radius_m() -> float:
    return float(getattr(settings, 'ROADWORK_MATCH_RADIUS_M', DEFAULT_MATCH_RADIUS_M))


# ── Geometry ────────────────────────────────────────────────────────────────

EARTH_RADIUS_M = 6_371_008.8


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in metres.

    Plenty accurate at the few-hundred-metre scale this is used at, and avoids
    pulling a geo stack in just to compare two points.
    """
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


# ── British National Grid → WGS84 ───────────────────────────────────────────
#
# Street Manager publishes geometry as WKT in EPSG:27700 (OSGB36 / British
# National Grid). Converting is a transverse-Mercator inverse onto the Airy 1830
# ellipsoid followed by a Helmert transform onto WGS84. The formulae are the
# standard ones from Ordnance Survey's "A guide to coordinate systems in Great
# Britain"; `test_roadworks.py` checks them against OS's published reference
# points, which is what makes hand-rolling this preferable to a compiled
# dependency on a small VPS.

# Airy 1830 (the ellipsoid OSGB36 is defined on)
_AIRY_A = 6377563.396
_AIRY_B = 6356256.909
# National Grid true origin and scale
_F0 = 0.9996012717
_LAT0 = math.radians(49.0)
_LON0 = math.radians(-2.0)
_E0 = 400000.0
_N0 = -100000.0

# WGS84
_WGS_A = 6378137.0
_WGS_B = 6356752.314245

# OSGB36 → WGS84 Helmert parameters
_TX, _TY, _TZ = 446.448, -125.157, 542.060
_RX = math.radians(0.1502 / 3600)
_RY = math.radians(0.2470 / 3600)
_RZ = math.radians(0.8421 / 3600)
_S = -20.4894e-6


def _osgb36_to_wgs84_cartesian(x: float, y: float, z: float) -> tuple[float, float, float]:
    return (
        _TX + x * (1 + _S) + (-_RZ) * y + _RY * z,
        _TY + _RZ * x + y * (1 + _S) + (-_RX) * z,
        _TZ + (-_RY) * x + _RX * y + z * (1 + _S),
    )


def bng_to_wgs84(easting: float, northing: float) -> tuple[float, float]:
    """Convert a British National Grid easting/northing to (latitude, longitude)."""
    a, b = _AIRY_A, _AIRY_B
    e2 = 1 - (b * b) / (a * a)
    n = (a - b) / (a + b)

    # Iterate northing to recover the footpoint latitude.
    lat = _LAT0
    m = 0.0
    for _ in range(100):
        lat = (northing - _N0 - m) / (a * _F0) + lat
        d_lat, s_lat = lat - _LAT0, lat + _LAT0
        ma = (1 + n + 1.25 * n * n + 1.25 * n ** 3) * d_lat
        mb = (3 * n + 3 * n * n + 2.625 * n ** 3) * math.sin(d_lat) * math.cos(s_lat)
        mc = (1.875 * n * n + 1.875 * n ** 3) * math.sin(2 * d_lat) * math.cos(2 * s_lat)
        md = (35 / 24) * n ** 3 * math.sin(3 * d_lat) * math.cos(3 * s_lat)
        m = b * _F0 * (ma - mb + mc - md)
        if abs(northing - _N0 - m) < 1e-5:
            break

    sin_lat, cos_lat, tan_lat = math.sin(lat), math.cos(lat), math.tan(lat)
    nu = a * _F0 / math.sqrt(1 - e2 * sin_lat ** 2)
    rho = a * _F0 * (1 - e2) / (1 - e2 * sin_lat ** 2) ** 1.5
    eta2 = nu / rho - 1

    t2, t4, t6 = tan_lat ** 2, tan_lat ** 4, tan_lat ** 6
    sec_lat = 1 / cos_lat

    vii = tan_lat / (2 * rho * nu)
    viii = tan_lat / (24 * rho * nu ** 3) * (5 + 3 * t2 + eta2 - 9 * t2 * eta2)
    ix = tan_lat / (720 * rho * nu ** 5) * (61 + 90 * t2 + 45 * t4)
    x_ = sec_lat / nu
    xi = sec_lat / (6 * nu ** 3) * (nu / rho + 2 * t2)
    xii = sec_lat / (120 * nu ** 5) * (5 + 28 * t2 + 24 * t4)
    xiia = sec_lat / (5040 * nu ** 7) * (61 + 662 * t2 + 1320 * t4 + 720 * t6)

    de = easting - _E0
    lat_osgb = lat - vii * de ** 2 + viii * de ** 4 - ix * de ** 6
    lon_osgb = _LON0 + x_ * de - xi * de ** 3 + xii * de ** 5 - xiia * de ** 7

    # Airy 1830 geodetic → cartesian, Helmert onto WGS84, then back to geodetic.
    sin_l, cos_l = math.sin(lat_osgb), math.cos(lat_osgb)
    v = a / math.sqrt(1 - e2 * sin_l ** 2)
    x = v * cos_l * math.cos(lon_osgb)
    y = v * cos_l * math.sin(lon_osgb)
    z = (1 - e2) * v * sin_l

    x, y, z = _osgb36_to_wgs84_cartesian(x, y, z)

    a2, b2 = _WGS_A, _WGS_B
    e2_w = 1 - (b2 * b2) / (a2 * a2)
    p = math.sqrt(x * x + y * y)
    lat_w = math.atan2(z, p * (1 - e2_w))
    for _ in range(10):
        v = a2 / math.sqrt(1 - e2_w * math.sin(lat_w) ** 2)
        new = math.atan2(z + e2_w * v * math.sin(lat_w), p)
        if abs(new - lat_w) < 1e-12:
            lat_w = new
            break
        lat_w = new
    lon_w = math.atan2(y, x)

    return math.degrees(lat_w), math.degrees(lon_w)


_WKT_POINT = re.compile(r'POINT\s*\(\s*([-\d.]+)\s+([-\d.]+)', re.I)
_WKT_MULTI = re.compile(r'(?:LINESTRING|POLYGON|MULTILINESTRING|MULTIPOLYGON)\s*\(+\s*(.+)', re.I)
_COORD_PAIR = re.compile(r'([-\d.]+)\s+([-\d.]+)')


def parse_wkt_centroid(wkt: str) -> tuple[float, float] | None:
    """Extract a representative BNG easting/northing from a WKT geometry.

    Street Manager sends POINT for spot works and LINESTRING for stretches of
    road. A single representative point is all the proximity check needs, so
    linestrings collapse to the mean of their vertices.
    """
    if not wkt:
        return None

    point = _WKT_POINT.search(wkt)
    if point:
        return float(point.group(1)), float(point.group(2))

    multi = _WKT_MULTI.search(wkt)
    if not multi:
        return None
    pairs = _COORD_PAIR.findall(multi.group(1))
    if not pairs:
        return None
    eastings = [float(e) for e, _ in pairs]
    northings = [float(n) for _, n in pairs]
    return sum(eastings) / len(eastings), sum(northings) / len(northings)


# ── Severity ────────────────────────────────────────────────────────────────

# Street Manager's traffic_management_type values, bucketed by how much they
# actually cost a driver. Anything unrecognised falls through to LOW rather than
# crying wolf on the dashboard.
#
# The feed's own enum mixes underscores, hyphens, slashes and spaces
# ('road_closure' but 'multi-way signals' but 'stop/go boards'), and nothing
# guarantees the case, so both these keys and the incoming value are normalised
# to space-separated lower case before comparison. Matching the raw strings
# would quietly bucket 'Road Closure' as LOW — a silently missing warning.
_HIGH = {'road closure'}
_MEDIUM = {
    'contra flow',
    'lane closure',
    'multi way signals',
    'two way signals',
    'convoy workings',
    'stop go boards',
    'priority working',
}


def _normalise_traffic_management(value: str) -> str:
    return re.sub(r'[\s_\-/]+', ' ', (value or '').strip().lower())


def severity_for(traffic_management: str) -> str:
    from .models import RoadworkIssue

    key = _normalise_traffic_management(traffic_management)
    if key in _HIGH:
        return RoadworkIssue.SEVERITY_HIGH
    if key in _MEDIUM:
        return RoadworkIssue.SEVERITY_MEDIUM
    return RoadworkIssue.SEVERITY_LOW


# ── Route matching ──────────────────────────────────────────────────────────


def issues_for_date(on_date: date):
    """Roadworks in force on `on_date`, newest-worst first."""
    from .models import RoadworkIssue

    return (
        RoadworkIssue.objects
        .filter(is_cancelled=False, start_date__lte=on_date, end_date__gte=on_date)
        .exclude(latitude__isnull=True)
        .exclude(longitude__isnull=True)
    )


def match_issues_to_routes(on_date: date, assignments=None) -> dict:
    """Work out which staff routes each of the day's roadworks disrupts.

    Returns `{issue_id: {'issue': RoadworkIssue, 'staff_ids': set, 'dog_ids': set}}`.

    `assignments` may be passed in when the caller has already loaded the day
    (the dashboard has), to avoid a second query. It must be an iterable of
    DailyDogAssignment with `dog` selected.
    """
    from .models import DailyDogAssignment

    issues = list(issues_for_date(on_date))
    if not issues:
        return {}

    if assignments is None:
        assignments = (
            DailyDogAssignment.objects
            .filter(date=on_date)
            .exclude(status='REMOVED')
            .exclude(staff_member__isnull=True)
            .select_related('dog')
        )

    # Only dogs the driver physically collects have a pickup address worth
    # matching, and only geocoded ones can be matched at all.
    located = [
        a for a in assignments
        if a.staff_member_id and a.dog.latitude is not None and a.dog.longitude is not None
    ]

    radius = match_radius_m()
    result: dict = {}
    for issue in issues:
        staff_ids, dog_ids = set(), set()
        for a in located:
            if haversine_m(issue.latitude, issue.longitude, a.dog.latitude, a.dog.longitude) <= radius:
                staff_ids.add(a.staff_member_id)
                dog_ids.add(a.dog_id)
        if staff_ids:
            result[issue.id] = {'issue': issue, 'staff_ids': staff_ids, 'dog_ids': dog_ids}
    return result
