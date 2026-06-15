"""UK postcode lookup (getAddress.io) + address geocoding (postcodes.io).

Two independent helpers:
- ``lookup_addresses`` powers the postcode-autofill endpoint
  (``api.views.postcode_lookup``) via getAddress.io; needs ``POSTCODE_LOOKUP_API_KEY``.
- ``geocode_address`` resolves a dog's address to coordinates for the staff
  pickup map via postcodes.io — free, no API key, postcode-centroid accuracy.

Uses the Python standard library only (``urllib``) so no extra pip dependency is
introduced — adding one to a single requirements file breaks the prod Docker
build.
"""
import json as _json
import re
import urllib.error
import urllib.parse
import urllib.request

from django.conf import settings


# Loose UK postcode matcher — good enough to pull a postcode out of a free-text
# address line. Matches the area+district+sector+unit shape with optional space.
_UK_POSTCODE_RE = re.compile(
    r'\b([A-Za-z]{1,2}\d[A-Za-z\d]?)\s*(\d[A-Za-z]{2})\b'
)


class PostcodeLookupError(Exception):
    """A provider error we should surface to the client."""


class PostcodeNotFound(PostcodeLookupError):
    """The postcode had no matching addresses."""


def extract_postcode(address):
    """Return the normalised, upper-cased UK postcode in a free-text address, or
    ``None``. Picks the last match, since the postcode comes at the end."""
    if not address:
        return None
    matches = list(_UK_POSTCODE_RE.finditer(address))
    if not matches:
        return None
    outward, inward = matches[-1].group(1), matches[-1].group(2)
    return f'{outward.upper()} {inward.upper()}'


def _provider_key():
    return getattr(settings, 'POSTCODE_LOOKUP_API_KEY', '')


def _fetch_getaddress(postcode, api_key):
    """Query getAddress.io ``/find`` (expanded) and return the parsed JSON dict.

    Raises :class:`PostcodeNotFound` / :class:`PostcodeLookupError`.
    """
    pc = urllib.parse.quote(postcode.replace(' ', ''))
    url = (
        f'https://api.getAddress.io/find/{pc}'
        f'?api-key={urllib.parse.quote(api_key)}&expand=true&sort=true'
    )
    req = urllib.request.Request(url, headers={'User-Agent': 'p4td-backend'})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return _json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise PostcodeNotFound()
        if exc.code == 400:
            raise PostcodeLookupError('That does not look like a valid postcode.')
        if exc.code in (401, 403):
            raise PostcodeLookupError('Postcode lookup is misconfigured (auth failed).')
        if exc.code == 429:
            raise PostcodeLookupError('Postcode lookup limit reached. Please try again later.')
        raise PostcodeLookupError('Address lookup service error.')
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise PostcodeLookupError('Could not reach the address lookup service.')


def _address_lines(addr):
    """Normalise a getAddress.io address entry to a list of non-empty lines."""
    if isinstance(addr, dict):
        parts = [
            addr.get('line_1'), addr.get('line_2'), addr.get('line_3'),
            addr.get('line_4'), addr.get('locality'),
            addr.get('town_or_city'), addr.get('county'),
        ]
    else:
        # Non-expanded form: a single comma-separated string.
        parts = str(addr).split(',')
    return [p.strip() for p in parts if p and p.strip()]


def lookup_addresses(postcode, api_key=None):
    """Return ``[{formatted, lines, postcode}, ...]`` for a postcode.

    This is what the postcode-autofill endpoint surfaces to the app.
    """
    api_key = api_key or _provider_key()
    if not api_key:
        raise PostcodeLookupError('Postcode lookup is not configured on the server.')
    payload = _fetch_getaddress(postcode, api_key)
    normalised_pc = (payload.get('postcode') or postcode).upper()
    results = []
    for addr in payload.get('addresses', []) or []:
        lines = _address_lines(addr)
        if not lines:
            continue
        results.append({
            'formatted': ', '.join(lines + [normalised_pc]),
            'lines': lines,
            'postcode': normalised_pc,
        })
    if not results:
        raise PostcodeNotFound()
    return results


def _coord(obj):
    """Return ``(lat, lng)`` floats from a dict carrying latitude/longitude, or
    ``None`` (also treats getAddress.io's 0/0 'unknown' sentinel as missing)."""
    if not isinstance(obj, dict):
        return None
    lat, lng = obj.get('latitude'), obj.get('longitude')
    try:
        if lat in (None, '') or lng in (None, ''):
            return None
        lat, lng = float(lat), float(lng)
    except (TypeError, ValueError):
        return None
    if lat == 0 and lng == 0:
        return None
    return (lat, lng)


def _fetch_postcodes_io(postcode):
    """Look up a postcode's centroid via postcodes.io (free, no API key).

    Returns the parsed JSON dict, or raises :class:`PostcodeNotFound` /
    :class:`PostcodeLookupError`.
    """
    pc = urllib.parse.quote(postcode.replace(' ', ''))
    url = f'https://api.postcodes.io/postcodes/{pc}'
    req = urllib.request.Request(url, headers={'User-Agent': 'p4td-backend'})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return _json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise PostcodeNotFound()
        raise PostcodeLookupError('Geocoding service error.')
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise PostcodeLookupError('Could not reach the geocoding service.')


def geocode_postcode(postcode):
    """Geocode a UK postcode to ``(lat, lng, source)`` via postcodes.io.

    ``source`` is ``'postcode'`` on success or ``'failed'`` when the postcode is
    blank, unknown, or has no coordinates. Never raises — returns
    ``(None, None, 'failed')`` on any error so callers degrade gracefully and the
    dog simply pins at base.
    """
    if not postcode:
        return (None, None, 'failed')
    try:
        payload = _fetch_postcodes_io(postcode)
    except PostcodeLookupError:
        return (None, None, 'failed')
    result = payload.get('result') if isinstance(payload, dict) else None
    coord = _coord(result)
    if coord:
        return (coord[0], coord[1], 'postcode')
    return (None, None, 'failed')


def geocode_address(address):
    """Geocode a free-text UK address by extracting its postcode (free, no API
    key). See :func:`geocode_postcode`."""
    return geocode_postcode(extract_postcode(address))


# Geocode field names cached on the Dog model.
GEOCODE_FIELDS = ['latitude', 'longitude', 'geocode_source', 'geocoded_address', 'geocoded_at']


def effective_postcode(dog):
    """The postcode used to place a dog: the structured ``postcode`` field if
    set, otherwise one parsed from the free-text ``address``. Upper-cased,
    normalised, or ``''`` when neither yields a postcode."""
    pc = (getattr(dog, 'postcode', '') or '').strip()
    if pc:
        return extract_postcode(pc) or pc.upper()
    return extract_postcode(dog.address) or ''


def geocode_dog(dog, force=False, save=True):
    """Refresh a Dog's cached pickup coordinates from its effective postcode.

    Prefers the structured ``postcode`` field, falling back to a postcode parsed
    from ``address``. Skips the network call when that postcode is unchanged
    since it was last geocoded (unless ``force``); clears coordinates when there
    is no usable postcode. Returns ``True`` if any geocode field was modified.
    Uses :func:`geocode_postcode`, which never raises.
    """
    from django.utils import timezone

    postcode = effective_postcode(dog)

    if not postcode:
        # No usable postcode → pin at base; clear any stale coordinates.
        already_clear = (
            dog.latitude is None and dog.longitude is None
            and not dog.geocode_source and not dog.geocoded_address
        )
        if already_clear:
            return False
        dog.latitude = None
        dog.longitude = None
        dog.geocode_source = ''
        dog.geocoded_address = ''
        dog.geocoded_at = timezone.now()
        if save:
            dog.save(update_fields=GEOCODE_FIELDS)
        return True

    # Already processed this exact postcode (success or failure) → leave it.
    if not force and dog.geocoded_address == postcode:
        return False

    lat, lng, source = geocode_postcode(postcode)
    dog.latitude = lat
    dog.longitude = lng
    dog.geocode_source = source
    dog.geocoded_address = postcode
    dog.geocoded_at = timezone.now()
    if save:
        dog.save(update_fields=GEOCODE_FIELDS)
    return True
