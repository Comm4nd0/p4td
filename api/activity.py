"""Viewset glue for the activity log — see ``DogChangeLog``.

``ActivityLogMixin`` gives a viewset one-line logging of the routine writes
(``log_created`` / ``log_updated`` / ``log_deleted``) with a field diff over
``activity_fields``, plus ``log`` for the bespoke actions (a status change, a
reply, an approval). Put it first in the bases so its default
``perform_update``/``perform_destroy`` sit in front of DRF's; a viewset with
its own ``perform_*`` calls the ``log_*`` helper itself.
"""
from .dog_changes import diff_fields, log_activity, snapshot_fields


def person(user):
    """A staff member or client as the log names them: full name, else
    username (an email) — staff-facing, like ``serializers.owner_display_name``."""
    from .dog_changes import actor_display
    return actor_display(user) if user is not None else ''


class ActivityLogMixin:
    #: One of ``DogChangeLog.CATEGORY_CHOICES``.
    activity_category = 'DOG'
    #: How the summary names the thing: "Added vehicle Big Van".
    activity_noun = 'record'
    #: ``{field: label}`` compared before/after an update.
    activity_fields = {}

    def activity_subject(self, obj):
        return str(obj)

    def activity_dog(self, obj):
        """The dog an entry is about, when it is about exactly one."""
        return None

    def activity_snapshot(self, obj):
        return snapshot_fields(obj, self.activity_fields)

    def log(self, obj, action, summary, *, changes=None, subject=None, dog=None, actor=None):
        return log_activity(
            self.activity_category,
            subject if subject is not None else self.activity_subject(obj),
            action=action,
            summary=summary,
            actor=actor if actor is not None else self.request.user,
            dog=dog if dog is not None else self.activity_dog(obj),
            changes=changes,
        )

    def log_created(self, obj, summary=None):
        return self.log(obj, 'CREATED', summary or f'Added {self.activity_noun} {self.activity_subject(obj)}')

    def log_updated(self, obj, before, summary=None):
        """Diff ``before`` (an ``activity_snapshot``) against ``obj`` now;
        writes nothing when no tracked field moved."""
        changes = diff_fields(before, self.activity_snapshot(obj), self.activity_fields)
        if not changes and summary is None:
            return None
        fields = ', '.join(c['label'].lower() for c in changes)
        return self.log(
            obj, 'UPDATED',
            summary or f'Updated {self.activity_noun} {self.activity_subject(obj)}: {fields}',
            changes=changes,
        )

    def log_deleted(self, obj, summary=None):
        return self.log(obj, 'DELETED', summary or f'Deleted {self.activity_noun} {self.activity_subject(obj)}')

    # Defaults for viewsets that don't customise the write itself.
    def perform_create(self, serializer):
        self.log_created(serializer.save())

    def perform_update(self, serializer):
        before = self.activity_snapshot(serializer.instance)
        self.log_updated(serializer.save(), before)

    def perform_destroy(self, instance):
        self.log_deleted(instance)
        instance.delete()
