import os
import sys
from contextlib import contextmanager

from django.core.management.base import BaseCommand, CommandError

from api.notifications import push_available, tracked_pushes, wait_for_pushes


def firebase_enforced():
    """Whether a reminder command refuses to run without Firebase.

    Always, except under the test runner (which has no credential and mocks
    the sends) and when ``P4TD_CRON_ALLOW_NO_PUSH=1`` says a box really has no
    Firebase and the commands should still do their bookkeeping.
    """
    if os.environ.get('P4TD_CRON_ALLOW_NO_PUSH', '').lower() in ('1', 'true', 'yes'):
        return False
    return 'test' not in sys.argv[1:2]


class PushCommand(BaseCommand):
    """A management command that may send pushes.

    Pushes go out on a background pool (``notifications.send_push_notification``),
    so a command must not exit until that pool has drained — otherwise the
    interpreter shuts down underneath it and every push fails. Use this as the
    base of any command that sends pushes, directly or through a model signal.

    A command whose whole job is the push (the reminder crons) sets
    ``requires_firebase``. It then refuses to start when the Firebase
    credential cannot be loaded: these commands mark a reminder sent *before*
    sending it, so running without Firebase used to burn every one-shot
    reminder due that day and still report success to the heartbeat. It also
    sends inside ``self.dispatch()``, which says whether FCM took the push, so
    a reminder nobody received can be put back and the run can exit non-zero.
    """

    requires_firebase = False

    def execute(self, *args, **options):
        self.push_failures = 0
        if (self.requires_firebase and not options.get('dry_run')
                and firebase_enforced() and not push_available()):
            raise CommandError(
                'Firebase is not initialised (FIREBASE_SERVICE_ACCOUNT_KEY missing or '
                'unreadable), so no push can be sent. Nothing was marked as sent and the '
                'heartbeat was not pinged.'
            )
        try:
            return super().execute(*args, **options)
        finally:
            wait_for_pushes()

    @contextmanager
    def dispatch(self):
        """Send the pushes for one reminder and learn how they went.

        Yields a ``PushOutcome``; after the block ``demonstrably_failed`` is
        true when somebody had a device and FCM took nothing. Each such
        reminder is counted, and ``fail_if_pushes_failed`` turns the count
        into a non-zero exit.
        """
        with tracked_pushes() as outcome:
            yield outcome
        if outcome.demonstrably_failed:
            self.push_failures += 1

    def fail_if_pushes_failed(self):
        """Call before the heartbeat: a run that could not deliver must not
        look healthy to the monitor."""
        if self.push_failures:
            raise CommandError(
                f'{self.push_failures} push(es) could not be delivered (see the log above).'
            )
