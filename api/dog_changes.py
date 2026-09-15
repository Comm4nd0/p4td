"""The audit trail behind ``DogChangeLog``: who changed what on a dog, and when.

Most entries are written by the ``Dog`` save signals in ``models.py``, which
snapshot the tracked fields before a save and diff them after — so a staff
PATCH, an approved owner change request, a booking-form approval and an edit
on the admin site all land here without each path having to remember to log.
The rest (vaccinations, gallery photos, notes, co-owner changes, deletion)
are written explicitly by the view that makes the change, because they don't
touch a tracked ``Dog`` field.

Attribution, in order of preference:

1. ``dog._audit_actor`` / ``dog._audit_source`` set on the instance by the
   caller (the approve path uses this to credit the approving staff member
   while ``_changed_by`` still names the owner for the care-instructions push);
2. the ``acting_as(user, source)`` context, for code that creates dogs via
   ``objects.create()`` / a serializer and never holds the instance first;
3. ``dog._changed_by``, the existing hook the care-instructions signal reads.

An entry with no actor is shown as "System" — a management command or a sync.
"""
import threading
from contextlib import contextmanager
from datetime import date, time
from decimal import Decimal

_state = threading.local()


@contextmanager
def acting_as(user, source='APP'):
    """Attribute every dog change made inside the block to ``user``."""
    previous = getattr(_state, 'context', None)
    _state.context = (user, source)
    try:
        yield
    finally:
        _state.context = previous


def current_context():
    return getattr(_state, 'context', None) or (None, None)


#: Dog fields the log watches, with the label the app shows. Everything
#: else on the model is bookkeeping (geocode cache, reminder flags, Xero
#: ids) and would only add noise.
TRACKED_FIELDS = {
    'name': 'Name',
    'owner': 'Owner',
    'profile_image': 'Profile photo',
    'food_instructions': 'Food instructions',
    'medical_notes': 'Medical notes',
    'registered_vet': 'Registered vet',
    'address': 'Address',
    'postcode': 'Postcode',
    'contact_number': 'Contact number',
    'emergency_contact_number': 'Emergency contact',
    'access_instructions': 'Pickup instructions',
    'van_placement': 'Van placement',
    'general_notes': 'General notes',
    'daycare_days': 'Daycare days',
    'schedule_type': 'Schedule type',
    'owner_brings_default': 'Owner brings',
    'owner_collects_default': 'Owner collects',
    'owner_brings_default_time': 'Drop-off time',
    'owner_collects_default_time': 'Pick-up time',
    'sex': 'Sex',
    'date_of_birth': 'Date of birth',
    'last_vaccination_date': 'Last vaccination',
    'is_spayed': 'Neutered',
    'daily_rate': 'Daily rate',
    'boarding_rate': 'Boarding rate',
    'billing_mode': 'Billing mode',
}

_WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
_CHOICE_FIELDS = ('schedule_type', 'sex', 'billing_mode')


def actor_display(user):
    """Full name, else username; '' for no user. Staff-facing, like
    ``serializers.owner_display_name``."""
    if user is None or not getattr(user, 'is_authenticated', True):
        return ''
    full = f"{user.first_name} {user.last_name}".strip()
    return full or user.username


def _display(dog, field):
    value = getattr(dog, field)
    if field == 'owner':
        return actor_display(value)
    if field == 'profile_image':
        return value.name.rsplit('/', 1)[-1] if value else ''
    if field == 'daycare_days':
        days = sorted({int(d) for d in (value or []) if str(d).isdigit() and 1 <= int(d) <= 7})
        return ', '.join(_WEEKDAYS[d - 1] for d in days)
    if field in _CHOICE_FIELDS:
        return getattr(dog, f'get_{field}_display')() if value else ''
    if isinstance(value, bool):
        return 'Yes' if value else 'No'
    if value is None:
        return ''
    if isinstance(value, (date, time)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return f'{value:.2f}'
    return str(value)


def snapshot(dog):
    """The tracked fields as display strings — what a diff compares."""
    return {field: _display(dog, field) for field in TRACKED_FIELDS}


def diff(before, after):
    return [
        {
            'field': field,
            'label': label,
            'old': before.get(field, ''),
            'new': after.get(field, ''),
        }
        for field, label in TRACKED_FIELDS.items()
        if before.get(field, '') != after.get(field, '')
    ]


def log_change(dog, *, action, summary, actor=None, source=None, changes=None, dog_name=None, category='DOG'):
    """Write one entry. ``dog`` may be None for a deletion (``dog_name`` then
    carries the name)."""
    from .models import DogChangeLog

    context_user, context_source = current_context()
    actor = actor if actor is not None else context_user
    if actor is not None and not getattr(actor, 'is_authenticated', True):
        actor = None
    return DogChangeLog.objects.create(
        category=category,
        dog=dog,
        dog_name=(dog_name or (dog.name if dog is not None else ''))[:150],
        actor=actor,
        actor_name=actor_display(actor),
        action=action,
        source=source or context_source or 'APP',
        summary=summary[:255],
        changes=changes or [],
    )


def log_activity(category, subject, *, action, summary, actor=None, dog=None, changes=None, source=None):
    """Write one non-dog entry (or a dog-linked one in another category —
    a booking decision, an assignment — when ``dog`` is given). ``subject`` is
    what the entry is about: a client, a vehicle, a staff member, a check."""
    return log_change(
        dog, dog_name=subject, action=action, summary=summary, actor=actor,
        source=source, changes=changes, category=category,
    )


def display_value(obj, field):
    """A field's value as the log shows it, for any model: choice labels,
    people by name, dates as ISO, booleans as Yes/No, decimals to 2dp."""
    value = getattr(obj, field, None)
    if hasattr(obj, f'get_{field}_display') and value not in (None, ''):
        return str(getattr(obj, f'get_{field}_display')())
    if value is None:
        return ''
    if hasattr(value, 'is_authenticated'):  # a User
        return actor_display(value)
    if hasattr(value, 'all') and callable(value.all):  # a many-to-many manager
        return ', '.join(sorted(str(v) for v in value.all()))
    if isinstance(value, bool):
        return 'Yes' if value else 'No'
    if isinstance(value, (date, time)):
        return value.isoformat()
    if hasattr(value, 'isoformat'):  # datetime
        return value.isoformat(timespec='minutes')
    if isinstance(value, Decimal):
        return f'{value:.2f}'
    if hasattr(value, 'name') and hasattr(value, 'url'):  # a FileField
        return value.name.rsplit('/', 1)[-1] if value else ''
    return str(value)


def snapshot_fields(obj, fields):
    """``{field: display}`` for the given ``{field: label}`` map — what a
    generic diff compares before and after a save."""
    return {field: display_value(obj, field) for field in fields}


def diff_fields(before, after, fields):
    return [
        {'field': field, 'label': label, 'old': before.get(field, ''), 'new': after.get(field, '')}
        for field, label in fields.items()
        if before.get(field, '') != after.get(field, '')
    ]


def _resolve_actor(dog):
    return (
        getattr(dog, '_audit_actor', None)
        or current_context()[0]
        or getattr(dog, '_changed_by', None)
    )


def _resolve_source(dog):
    return getattr(dog, '_audit_source', None) or current_context()[1] or 'APP'


def record_save(dog, created):
    """Called from the ``Dog`` post_save signal."""
    actor = _resolve_actor(dog)
    source = _resolve_source(dog)
    if created:
        owner = actor_display(dog.owner)
        log_change(
            dog,
            action='CREATED',
            actor=actor,
            source=source,
            summary=f'Added {dog.name}' + (f' for {owner}' if owner else ''),
        )
        return

    before = getattr(dog, '_audit_before', None)
    dog._audit_before = None
    if before is None:
        return
    changes = diff(before, snapshot(dog))
    if not changes:
        return
    fields = ', '.join(c['label'].lower() for c in changes)
    prefix = getattr(dog, '_audit_summary_prefix', None)
    only_owner = len(changes) == 1 and changes[0]['field'] == 'owner'
    log_change(
        dog,
        action='OWNER_CHANGED' if only_owner else 'UPDATED',
        actor=actor,
        source=source,
        summary=f'{prefix} {fields}' if prefix else f'Updated {fields}',
        changes=changes,
    )


def record_delete(dog):
    """Called from the ``Dog`` pre_delete signal. The entry keeps only the
    name — the row it pointed at is about to go."""
    log_change(
        None,
        dog_name=dog.name,
        action='DELETED',
        actor=_resolve_actor(dog),
        source=_resolve_source(dog),
        summary=f'Deleted {dog.name}',
    )
