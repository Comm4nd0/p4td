"""Dead-man's-switch heartbeat for scheduled management commands (I7).

Scheduled commands (vaccination/fleet reminders, feed pruning) previously had no
failure signal — if one started erroring, owners simply stopped getting reminders
and pruning silently stopped. This pings a monitoring URL ONLY on a successful
run, so a service like healthchecks.io alerts when a command stops checking in
(crash, migration mismatch, expired Firebase creds, etc.).

Set ``P4TD_CRON_HEARTBEAT_URL`` to the base check URL. The per-command ``suffix``
is appended so one base URL can fan out to per-job checks (e.g. healthchecks.io
slug-style ``<base>/<suffix>``). No-op when the env var is unset, and never
raises, so it can't fail the command it's reporting on.
"""
import logging
import os
import urllib.request

logger = logging.getLogger(__name__)


def ping_heartbeat(suffix=''):
    base = os.environ.get('P4TD_CRON_HEARTBEAT_URL', '').strip()
    if not base:
        return
    url = base.rstrip('/') + (f'/{suffix}' if suffix else '')
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'p4td-cron'})
        urllib.request.urlopen(req, timeout=5).close()
    except Exception as exc:  # best-effort — monitoring must never break the job
        logger.warning('Heartbeat ping failed for %s: %s', suffix or 'cron', exc)
