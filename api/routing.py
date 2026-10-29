"""Pickup-route planning: drive times from OpenRouteService, solved here.

Two jobs, both suggestions that staff accept or ignore:

- ``best_order`` — the quickest order to visit one driver's dogs, starting and
  ending at the daycare base ("Optimise route" on a driver's list).
- ``plan_routes`` — share the day's dogs between the drivers working it, then
  order each run ("Plan Routes" on the dashboard).

OpenRouteService only supplies the drive-time matrix; the solving is a small
local search in plain Python. OR-Tools would do it too, but it pulls numpy,
pandas and protobuf into the image for a problem this size (a few vans, a few
dozen stops), and the rules that matter here — keep dogs with their usual
driver, keep incompatible dogs apart, keep a household in one van — are
easier to state as costs in our own objective than to bend a generic solver
around.

Uses the standard library only (``urllib``), like ``api.geocoding``: adding a
pip dependency to one requirements file breaks the production Docker build.

Coordinates are the postcode centroids ``geocode_dogs`` caches on each dog, so
the times are good for comparing routes, not for promising an arrival time.
"""
import hashlib
import itertools
import json as _json
import math
import urllib.error
import urllib.request
from dataclasses import dataclass, field

from django.conf import settings
from django.core.cache import cache

ORS_MATRIX_URL = 'https://api.openrouteservice.org/v2/matrix/driving-car'

# The free ORS plan allows 3500 elements (sources x destinations) per matrix
# request; 59 x 59 = 3481 keeps each tile under it.
_MATRIX_TILE = 59

# Drive times barely change, and the free plan allows 500 matrix requests a
# day, so a set of locations is fetched once a fortnight at most.
_MATRIX_CACHE_SECONDS = 14 * 24 * 3600

# How much a suggestion must save before it moves a dog off its usual driver.
# Owners and dogs value the same face every day; a plan that reshuffles the
# whole board to save a minute or two is worse in practice, not better.
MOVE_PENALTY_SECONDS = 5 * 60

# Everyone works until the last van is back, so the longest run counts on top
# of the total driving: it stops the plan piling every dog onto one van.
LONGEST_RUN_WEIGHT = 1.0

# Effectively hard rules, expressed as costs so a board that already breaks
# them still gets a plan (the best one available) rather than an error.
OVER_CAPACITY_PENALTY = 10_000
CONFLICT_PENALTY = 100_000

# Exhaustive search is exact and instant for short runs; beyond this the
# heuristic takes over.
_BRUTE_FORCE_MAX_STOPS = 7


class RoutingError(Exception):
    """A routing failure worth showing to staff."""


class RoutingNotConfigured(RoutingError):
    """No ORS key or no base postcode on the server."""


def is_configured():
    return bool(
        getattr(settings, 'OPENROUTESERVICE_API_KEY', '')
        and getattr(settings, 'ROUTING_BASE_POSTCODE', '')
    )


def base_location():
    """The daycare base as ``(lat, lng)``, geocoded from ROUTING_BASE_POSTCODE
    and cached."""
    if not is_configured():
        raise RoutingNotConfigured('Route planning is not set up on the server.')
    postcode = settings.ROUTING_BASE_POSTCODE.strip().upper()
    key = 'routing:base:' + postcode.replace(' ', '')
    cached = cache.get(key)
    if cached:
        return tuple(cached)
    from .geocoding import geocode_postcode, PostcodeLookupError
    try:
        result = geocode_postcode(postcode)
    except PostcodeLookupError:
        result = None
    if not result:
        raise RoutingError(f'Could not locate the daycare base postcode {postcode}.')
    point = (round(result[0], 5), round(result[1], 5))
    cache.set(key, list(point), _MATRIX_CACHE_SECONDS)
    return point


def point_of(lat, lng):
    """A location key: coordinates rounded to ~1 m, so dogs at one address
    share a stop."""
    if lat is None or lng is None:
        return None
    return (round(lat, 5), round(lng, 5))


# ─── Drive times ─────────────────────────────────────────────────────────────

def _haversine_seconds(a, b):
    """Rough drive time for a pair ORS couldn't route: straight line, 30%
    detour, 40 km/h."""
    lat1, lng1, lat2, lng2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2)
    metres = 2 * 6_371_000 * math.asin(math.sqrt(h))
    return metres * 1.3 / (40_000 / 3600)


def _fetch_matrix_tile(points, sources, destinations):
    body = _json.dumps({
        'locations': [[lng, lat] for lat, lng in points],
        'sources': sources,
        'destinations': destinations,
        'metrics': ['duration'],
    }).encode('utf-8')
    req = urllib.request.Request(
        ORS_MATRIX_URL, data=body, method='POST',
        headers={
            'Authorization': settings.OPENROUTESERVICE_API_KEY,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'User-Agent': 'p4td-backend',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = _json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise RoutingError('OpenRouteService refused the API key.')
        if exc.code == 429:
            raise RoutingError('OpenRouteService daily limit reached. Try again later.')
        raise RoutingError(f'OpenRouteService error ({exc.code}).')
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise RoutingError('Could not reach OpenRouteService.')
    durations = payload.get('durations')
    if not isinstance(durations, list):
        raise RoutingError('OpenRouteService returned no drive times.')
    return durations


def fetch_drive_times(points):
    """Seconds from every point to every other, as a square list of lists,
    fetched from ORS in tiles. Pairs ORS can't route fall back to an estimate."""
    n = len(points)
    matrix = [[0.0] * n for _ in range(n)]
    blocks = [list(range(i, min(i + _MATRIX_TILE, n))) for i in range(0, n, _MATRIX_TILE)]
    for src in blocks:
        for dst in blocks:
            # Only the locations this tile needs go in the request.
            tile_ids = sorted(set(src) | set(dst))
            local = {g: i for i, g in enumerate(tile_ids)}
            rows = _fetch_matrix_tile(
                [points[g] for g in tile_ids],
                [local[g] for g in src],
                [local[g] for g in dst],
            )
            for r, s in enumerate(src):
                for c, d in enumerate(dst):
                    value = rows[r][c] if r < len(rows) and c < len(rows[r]) else None
                    matrix[s][d] = float(value) if value is not None else _haversine_seconds(points[s], points[d])
    return matrix


def drive_times(points):
    """``fetch_drive_times`` behind the shared cache."""
    digest = hashlib.sha1(_json.dumps(points).encode('utf-8')).hexdigest()
    key = f'routing:matrix:{digest}'
    cached = cache.get(key)
    if cached is not None:
        return cached
    matrix = fetch_drive_times(points)
    cache.set(key, matrix, _MATRIX_CACHE_SECONDS)
    return matrix


# ─── One run ─────────────────────────────────────────────────────────────────

def tour_seconds(order, matrix, base=0):
    """Base → each stop in ``order`` → base."""
    total, here = 0.0, base
    for stop in order:
        total += matrix[here][stop]
        here = stop
    return total + matrix[here][base]


def _nearest_neighbour(stops, matrix, base):
    remaining, order, here = list(stops), [], base
    while remaining:
        nxt = min(remaining, key=lambda s: (matrix[here][s], s))
        order.append(nxt)
        remaining.remove(nxt)
        here = nxt
    return order


def _improve(order, matrix, base):
    """2-opt and or-opt (move a run of 1–3 stops) until nothing helps. Each
    candidate is costed in full, because drive times aren't symmetric."""
    best, best_cost = list(order), tour_seconds(order, matrix, base)
    n = len(best)
    improved = True
    while improved:
        improved = False
        for i in range(n - 1):
            for j in range(i + 1, n):
                cand = best[:i] + best[i:j + 1][::-1] + best[j + 1:]
                cost = tour_seconds(cand, matrix, base)
                if cost < best_cost - 1e-6:
                    best, best_cost, improved = cand, cost, True
        for length in (1, 2, 3):
            for i in range(n - length + 1):
                segment = best[i:i + length]
                rest = best[:i] + best[i + length:]
                for k in range(len(rest) + 1):
                    if k == i:
                        continue
                    cand = rest[:k] + segment + rest[k:]
                    cost = tour_seconds(cand, matrix, base)
                    if cost < best_cost - 1e-6:
                        best, best_cost, improved = cand, cost, True
    return best, best_cost


def quick_tour_seconds(stops, matrix, base=0):
    """A fast, slightly pessimistic run time by cheapest insertion — good
    enough to compare candidate plans; ``best_order`` orders the winner."""
    tour = []
    for stop in sorted(stops, key=lambda s: (-(matrix[base][s] + matrix[s][base]), s)):
        if not tour:
            tour = [stop]
            continue
        path = [base] + tour + [base]
        k = min(range(len(path) - 1), key=lambda k: (
            matrix[path[k]][stop] + matrix[stop][path[k + 1]] - matrix[path[k]][path[k + 1]], k))
        tour.insert(k, stop)
    return tour_seconds(tour, matrix, base)


def best_order(stops, matrix, base=0):
    """Quickest order to visit ``stops`` (matrix indexes, distinct), from and
    back to ``base``. Returns ``(order, seconds)``. Exact for short runs."""
    stops = sorted(set(stops))
    if not stops:
        return [], 0.0
    if len(stops) <= _BRUTE_FORCE_MAX_STOPS:
        best = min(itertools.permutations(stops), key=lambda p: (tour_seconds(p, matrix, base), p))
        return list(best), tour_seconds(best, matrix, base)
    # Two starting tours — nearest-neighbour out from the base, and the
    # reverse of nearest-neighbour back to it — improved, keep the better.
    forward = _nearest_neighbour(stops, matrix, base)
    transposed = [list(col) for col in zip(*matrix)]
    backward = _nearest_neighbour(stops, transposed, base)[::-1]
    results = [_improve(start, matrix, base) for start in (forward, backward)]
    return min(results, key=lambda r: (r[1], r[0]))


# ─── The whole day ───────────────────────────────────────────────────────────

@dataclass
class PlanDog:
    """One dog on the day's board, as the planner sees it."""
    assignment_id: int
    dog_id: int
    current_staff_id: int | None
    stop: int | None          # matrix index, None when the dog has no location
    pickup: bool = True
    dropoff: bool = True
    pinned: bool = False      # already collected/returned, or unlocated: stays put


@dataclass
class PlanDriver:
    staff_id: int
    capacity: int | None = None   # None = no limit known


@dataclass
class _Unit:
    """Dogs that move together: one address, one current driver."""
    dogs: list
    stop: int | None
    current: int | None
    pinned: bool
    dog_ids: frozenset = field(default_factory=frozenset)


@dataclass
class PlannedRoute:
    staff_id: int
    assignment_ids: list       # in visiting order; unlocated dogs last
    seconds: float
    load: int
    capacity: int | None


@dataclass
class Plan:
    routes: list               # PlannedRoute per driver, in the drivers' order
    unplaced: list             # assignment ids the plan couldn't put anywhere
    conflicts: list            # sets of dog ids still sharing a van
    over_capacity: list        # staff ids still over their van's capacity


def _load(units):
    return max(
        sum(1 for u in units for d in u.dogs if d.pickup),
        sum(1 for u in units for d in u.dogs if d.dropoff),
    )


def plan_routes(dogs, drivers, matrix, conflicts=(), base=0):
    """Share ``dogs`` (PlanDog) between ``drivers`` (PlanDriver) and order
    each run.

    Starts from the board as it stands — each dog with its current driver
    where that driver is on the plan — places the rest where they cost least,
    then moves or swaps households between vans while that lowers the
    objective: total driving, plus the longest run, plus
    ``MOVE_PENALTY_SECONDS`` per dog taken off its current driver, plus heavy
    penalties for an over-full van or for every dog of a ``conflicts`` group
    (sets of dog ids) riding together. Deterministic for the same input.
    """
    driver_ids = [d.staff_id for d in drivers]
    if not driver_ids:
        return Plan(routes=[], unplaced=[d.assignment_id for d in dogs], conflicts=[], over_capacity=[])
    capacity = {d.staff_id: d.capacity for d in drivers}
    conflicts = [frozenset(c) for c in conflicts if len(c) >= 2]

    quarrelsome = set().union(*conflicts) if conflicts else set()
    grouped = {}
    unplaced = []
    for dog in dogs:
        if dog.stop is None and (dog.current_staff_id not in capacity):
            unplaced.append(dog.assignment_id)
            continue
        pinned = dog.pinned or dog.stop is None
        if pinned and dog.current_staff_id not in capacity:
            unplaced.append(dog.assignment_id)
            continue
        if pinned:
            key = ('pinned', dog.assignment_id)
        elif dog.dog_id in quarrelsome:
            # A household normally travels together, but not when the note
            # is about two of its own dogs: each must be free to move alone.
            key = ('alone', dog.assignment_id)
        else:
            key = ('free', dog.stop, dog.current_staff_id)
        grouped.setdefault(key, []).append(dog)
    units = []
    for key in sorted(grouped, key=str):
        members = grouped[key]
        units.append(_Unit(
            dogs=members, stop=members[0].stop, current=members[0].current_staff_id,
            pinned=key[0] == 'pinned', dog_ids=frozenset(d.dog_id for d in members),
        ))

    tour_cache = {}

    def run_seconds(stops):
        key = frozenset(stops)
        if key not in tour_cache:
            tour_cache[key] = quick_tour_seconds(key, matrix, base)
        return tour_cache[key]

    van_cache = {}

    def van(staff, members):
        """(drive seconds, penalties) for one van carrying unit indexes
        ``members``."""
        key = (staff, members)
        if key not in van_cache:
            chosen = [units[i] for i in members]
            secs = run_seconds({u.stop for u in chosen if u.stop is not None})
            penalty = 0.0
            cap = capacity[staff]
            if cap is not None:
                penalty += OVER_CAPACITY_PENALTY * max(0, _load(chosen) - cap)
            riders = frozenset().union(*(u.dog_ids for u in chosen)) if chosen else frozenset()
            penalty += CONFLICT_PENALTY * sum(1 for c in conflicts if c <= riders)
            penalty += MOVE_PENALTY_SECONDS * sum(len(u.dogs) for u in chosen if u.current != staff)
            van_cache[key] = (secs, penalty)
        return van_cache[key]

    def objective(loads):
        """Total for ``loads`` — {staff id: frozenset of unit indexes}."""
        parts = [van(staff, members) for staff, members in loads.items()]
        return (sum(secs + pen for secs, pen in parts)
                + LONGEST_RUN_WEIGHT * max(secs for secs, _ in parts))

    # Start: current driver where possible; everyone else placed one at a
    # time where they add least.
    loads = {staff: frozenset() for staff in driver_ids}
    for i, unit in enumerate(units):
        if unit.current in capacity:
            loads[unit.current] = loads[unit.current] | {i}
    for i, unit in enumerate(units):
        if unit.current in capacity:
            continue

        def with_unit(staff):
            trial = dict(loads)
            trial[staff] = trial[staff] | {i}
            return objective(trial)
        target = min(driver_ids, key=lambda staff: (with_unit(staff), driver_ids.index(staff)))
        loads[target] = loads[target] | {i}

    where = {i: staff for staff, members in loads.items() for i in members}
    movable = [i for i, u in enumerate(units) if not u.pinned]
    current_cost = objective(loads)
    for _ in range(500):
        best_move = None
        for i in movable:
            src = where[i]
            for dst in driver_ids:
                if dst == src:
                    continue
                trial = dict(loads)
                trial[src] = trial[src] - {i}
                trial[dst] = trial[dst] | {i}
                c = objective(trial)
                if c < current_cost - 1e-6 and (best_move is None or c < best_move[0]):
                    best_move = (c, trial)
        for a, b in itertools.combinations(movable, 2):
            sa, sb = where[a], where[b]
            if sa == sb:
                continue
            trial = dict(loads)
            trial[sa] = (trial[sa] - {a}) | {b}
            trial[sb] = (trial[sb] - {b}) | {a}
            c = objective(trial)
            if c < current_cost - 1e-6 and (best_move is None or c < best_move[0]):
                best_move = (c, trial)
        if best_move is None:
            break
        current_cost, loads = best_move
        where = {i: staff for staff, members in loads.items() for i in members}

    routes, still_conflicting, over = [], [], []
    for staff in driver_ids:
        members = [units[i] for i in sorted(loads[staff])]
        stops = {u.stop for u in members if u.stop is not None}
        order, secs = best_order(stops, matrix, base)
        position = {stop: n for n, stop in enumerate(order)}
        ordered = sorted(
            (d for u in members for d in u.dogs),
            key=lambda d: (d.stop is None, position.get(d.stop, 0), d.assignment_id),
        )
        load = _load(members)
        if capacity[staff] is not None and load > capacity[staff]:
            over.append(staff)
        riders = frozenset(d.dog_id for d in ordered)
        still_conflicting.extend(set(c) for c in conflicts if c <= riders)
        routes.append(PlannedRoute(
            staff_id=staff, assignment_ids=[d.assignment_id for d in ordered],
            seconds=secs, load=load, capacity=capacity[staff],
        ))
    return Plan(routes=routes, unplaced=unplaced, conflicts=still_conflicting, over_capacity=over)

