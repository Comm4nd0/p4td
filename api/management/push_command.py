from django.core.management.base import BaseCommand

from api.notifications import wait_for_pushes


class PushCommand(BaseCommand):
    """A management command that may send pushes.

    Pushes go out on a background pool (``notifications.send_push_notification``),
    so a command must not exit until that pool has drained — otherwise the
    interpreter shuts down underneath it and every push fails. Use this as the
    base of any command that sends pushes, directly or through a model signal.
    """

    def execute(self, *args, **options):
        try:
            return super().execute(*args, **options)
        finally:
            wait_for_pushes()
