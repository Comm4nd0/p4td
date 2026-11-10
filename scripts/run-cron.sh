#!/usr/bin/env bash
# =============================================================================
# Run one scheduled p4td job. Every line scripts/install-cron.sh writes to the
# crontab goes through here.
#
#   run-cron.sh [--london-hour HH] <log-name> manage <manage.py command> [args...]
#   run-cron.sh [--london-hour HH] <log-name> host   <command> [args...]
#
# Three things a bare crontab line got wrong:
#
# * The clock. The business runs on UK time; the server's clock is UTC. A job
#   written as "8am" ran at 9am all summer. With --london-hour the crontab line
#   fires every hour and this script runs the job only in the hour that is HH
#   in London, whatever the host's timezone or the season.
#
# * Deploys. `docker compose exec` fails outright while a deploy is replacing
#   the web container, and cron does not retry: the job for that day was simply
#   lost. `manage` waits for the container to come back (up to
#   $P4TD_CRON_WAIT_SECONDS, default 20 minutes) and then runs the command
#   once. It waits for the container, never retries the command — a reminder
#   run that got halfway must not be started again from the top.
#
# * Overlap. A job still running when its next slot comes round (the Xero sync
#   is every 30 minutes) is skipped rather than run twice at once.
#
# Output is appended to /var/log/p4td-<log-name>.log ($P4TD_CRON_LOG_DIR to
# move it). The exit status is the job's own.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"

london_hour=""
if [ "${1:-}" = "--london-hour" ]; then
    london_hour="${2:-}"
    shift 2
fi

if [ "$#" -lt 3 ]; then
    echo "usage: $0 [--london-hour HH] <log-name> manage|host <command> [args...]" >&2
    exit 2
fi

log_name="$1"
mode="$2"
shift 2

# Not this hour in London: nothing to do, and nothing worth logging 23 times a day.
if [ -n "$london_hour" ] && [ "$(TZ=Europe/London date +%H)" != "$london_hour" ]; then
    exit 0
fi

log_dir="${P4TD_CRON_LOG_DIR:-/var/log}"
log_file="$log_dir/p4td-$log_name.log"
if ! exec >>"$log_file" 2>&1; then
    echo "run-cron.sh: cannot write to $log_file" >&2
    exit 1
fi

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cd "$REPO_ROOT" || { echo "[$(stamp)] cannot cd to $REPO_ROOT"; exit 1; }

# One run of a given job at a time. The lock is named for the job (its whole
# command), not the log, because two jobs may share a log file.
job_name="$1"
if [ "$mode" = "host" ]; then
    # "bash /path/to/backup-db.sh" is better known as backup-db.sh.
    for word in "$@"; do job_name="$(basename "$word")"; done
fi
job_key="$(printf '%s' "$mode-$*" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-120)"
if command -v flock >/dev/null 2>&1; then
    exec 9>"/tmp/p4td-cron-$job_key.lock"
    if ! flock -n 9; then
        echo "[$(stamp)] $job_name: previous run still going; skipped."
        exit 0
    fi
fi

case "$mode" in
    manage)
        wait_seconds="${P4TD_CRON_WAIT_SECONDS:-1200}"
        waited=0
        until docker compose -f "$COMPOSE_FILE" exec -T web true >/dev/null 2>&1; do
            if [ "$waited" -ge "$wait_seconds" ]; then
                echo "[$(stamp)] $job_name: web container not available after ${waited}s; NOT run."
                exit 1
            fi
            if [ "$waited" -eq 0 ]; then
                echo "[$(stamp)] $job_name: web container not available (deploy in progress?); waiting."
            fi
            sleep 15
            waited=$((waited + 15))
        done
        docker compose -f "$COMPOSE_FILE" exec -T web python manage.py "$@"
        status=$?
        ;;
    host)
        "$@"
        status=$?
        ;;
    *)
        echo "[$(stamp)] unknown mode '$mode' (expected manage or host)"
        exit 2
        ;;
esac

if [ "$status" -ne 0 ]; then
    echo "[$(stamp)] $job_name: FAILED with exit status $status"
fi
exit "$status"
