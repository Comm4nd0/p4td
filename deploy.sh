#!/bin/bash
# Deploy P4TD from a checkout *on the server*.
# Usage: ./deploy.sh [--skip-pull] [--no-cache]
#
# This is the one deploy path. The automatic deploy
# (.github/workflows/deploy-backend.yml) and scripts/deploy-to-hetzner.sh (from
# a laptop) both SSH in and run exactly this.
#
# Order of events, and what a failure at each leaves behind:
#
#   1. rollback point recorded, code pulled (--ff-only), image built
#        fails -> nothing has changed; the old container is still serving.
#   2. pending migrations? then: database dumped, migrations applied by a
#      one-off container running the NEW image
#        dump fails    -> stop; nothing has changed.
#        migrate fails -> stop; the old container is STILL SERVING the old
#                         code. (It used to be gone by this point, so a bad
#                         migration was an outage until someone woke up.)
#   3. serving container swapped (`up -d`), health-gated
#        fails -> the new container is up but unhealthy; roll back by hand
#                 with the command printed.
#   4. crontab refreshed, old images pruned
#        fails -> a warning; the deploy itself has succeeded.

set -euo pipefail

COMPOSE_FILE="docker-compose.prod.yml"
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

echo "=================================================="
echo "  Deploying Paws 4 Thought Dogs"
echo "=================================================="

# One deploy at a time. The workflow serialises its own runs, but a manual
# ./deploy.sh can still land on top of an automatic one. Skipped on the
# re-exec below, which is the same deploy and already holds the lock (the
# descriptor survives `exec`).
if [ -z "${P4TD_DEPLOY_REEXEC:-}" ] && command -v flock >/dev/null 2>&1; then
    exec 8>/tmp/p4td-deploy.lock
    if ! flock -n 8; then
        echo "!!! Another deploy is already running on this server. Not starting a second." >&2
        exit 1
    fi
fi

# 0. Record a rollback point BEFORE anything changes.
#
# scripts/deploy-to-hetzner.sh has always done this; deploy.sh did not, which
# meant an automated deploy (see .github/workflows/deploy-backend.yml) had no
# recorded target to roll back to when it failed. Written before the pull so the
# commit captured is the one currently serving traffic.
#
# On the re-exec below the point was already recorded by the first pass, before
# the pull moved HEAD — so it is handed across in P4TD_PREV_COMMIT. (It used
# not to be, and every later mention of $PREV_COMMIT then died on `set -u`,
# exactly when the rollback command was needed.) A first pass too old to hand
# it across leaves it as the last line of .deploy-history.
if [ -z "${P4TD_DEPLOY_REEXEC:-}" ]; then
    PREV_COMMIT="$(git rev-parse HEAD)"
    PREV_IMAGE="$(compose images -q web 2>/dev/null || echo '')"
    printf '%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PREV_COMMIT" "$PREV_IMAGE" >> .deploy-history
    echo ""
    echo ">>> Rollback point: $PREV_COMMIT (web image ${PREV_IMAGE:-none})"
else
    PREV_COMMIT="${P4TD_PREV_COMMIT:-}"
    if [ -z "$PREV_COMMIT" ] && [ -f .deploy-history ]; then
        PREV_COMMIT="$(tail -n 1 .deploy-history | cut -f2)"
    fi
    PREV_COMMIT="${PREV_COMMIT:-<see .deploy-history>}"
    echo ""
    echo ">>> Rollback point (recorded before the pull): $PREV_COMMIT"
fi

# 1. Pull latest code.
#
# main only. This used to pull `development` first and then `main`, which
# merged unreviewed work-in-progress into production with no trace in
# `git log origin/main`. --ff-only means a diverged server checkout fails
# loudly here rather than silently creating a merge commit on the box.
if [[ "$*" != *"--skip-pull"* ]]; then
    echo ""
    echo ">>> Pulling latest code from main..."
    SELF_BEFORE="$(git rev-parse HEAD:deploy.sh)"
    git fetch origin main
    git pull --ff-only origin main
    # If the pull changed this very script, run the new one instead of
    # carrying on with the old. bash executes the copy it opened at start —
    # git replaces the file with a new inode — so without this a change to
    # deploy.sh only takes effect on the deploy *after* the one that shipped
    # it. That is how the private-media ownership step below shipped without
    # running. --skip-pull: the code is already current.
    if [ "$(git rev-parse HEAD:deploy.sh)" != "$SELF_BEFORE" ]; then
        echo ""
        echo ">>> deploy.sh changed in this pull; re-running the new version..."
        P4TD_DEPLOY_REEXEC=1 P4TD_PREV_COMMIT="$PREV_COMMIT" exec ./deploy.sh --skip-pull "$@"
    fi
else
    echo ""
    echo ">>> Skipping git pull (--skip-pull)"
fi

DEPLOYING_COMMIT="$(git rev-parse --short HEAD)"
echo ">>> Deploying commit: $DEPLOYING_COMMIT"

rollback_hint() {
    echo "!!! To roll back: git checkout $PREV_COMMIT && ./deploy.sh --skip-pull"
}

# 2. Build containers (includes collectstatic in Dockerfile)
echo ""
echo ">>> Building Docker images..."
if [[ "$*" == *"--no-cache"* ]]; then
    compose build --no-cache
else
    compose build
fi

# 3. Make sure the private-media bind mount is writable by the app.
#
# The image runs as `appuser` (uid 1000). When a bind-mount source is missing,
# the Docker daemon creates it as root:root 755, and the container can then
# never write into it. That is exactly how vaccination-certificate uploads
# 500'd with "Permission denied: /app/private-media/vaccination_certificates"
# after the feature first shipped — private-media/ was born root-owned on the
# first `up`. Create it here, before `up -d`, with the uid the container
# actually uses. Only the top-level directory is touched: files already inside
# are the app's own and must be left alone. (media/ predates this and is
# world-writable, so it needs no help.)
echo ""
echo ">>> Ensuring private-media/ is writable by the app (uid 1000)..."
mkdir -p private-media
if [ "$(stat -c '%u' private-media)" != "1000" ]; then
    chown 1000:1000 private-media
fi
chmod 770 private-media

# 4. Migrate BEFORE swapping the serving container.
#
# `up -d` stops the old container first and the new one ran `migrate` as part
# of starting, so a migration that failed left nothing serving at all — a
# crash-looping container, at night, with nobody watching. Now the migration is
# run by a throwaway container from the image just built, while the old
# container carries on serving. If it fails, the deploy stops here and the site
# is still up on the old code.
#
# The price is a short window in which the old code runs against the new
# schema (between this step and step 5). That is the usual rule for any deploy
# without downtime: a migration must not break the code it replaces — add
# first, remove in a later release.
#
# The serving container's own command still runs `migrate --noinput`; by then
# there is nothing left to apply, so it is a no-op kept as a safety net for a
# plain `docker compose up`.
echo ""
echo ">>> Checking for pending migrations..."
if compose run --rm -T web python manage.py migrate --check </dev/null >/dev/null 2>&1; then
    echo "    None pending."
else
    # Either there are migrations to apply, or the check itself could not run
    # (database down, bad settings). Both go the same way: dump what can be
    # dumped, then let `migrate` succeed or say what is wrong.
    echo "    Migrations to apply (or the check could not run)."

    # A dump first, so a migration that mangles data — not just one that
    # fails — has something to go back to. Only when the database is already
    # running: on a first-ever deploy there is nothing to dump.
    if compose exec -T db true </dev/null >/dev/null 2>&1; then
        mkdir -p backups
        chmod 700 backups
        PREDEPLOY_DUMP="backups/predeploy-$(date -u +%Y%m%dT%H%M%SZ)-${DEPLOYING_COMMIT}.dump"
        echo ""
        echo ">>> Dumping the database to $PREDEPLOY_DUMP before migrating..."
        # Inside the db container, with its own POSTGRES_* variables, over its
        # local socket: no password to pass and no client needed on the host.
        # shellcheck disable=SC2016  # expanded by the container's shell, not this one
        if compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
                </dev/null > "$PREDEPLOY_DUMP.partial" && [ -s "$PREDEPLOY_DUMP.partial" ]; then
            mv "$PREDEPLOY_DUMP.partial" "$PREDEPLOY_DUMP"
            echo "    Dump complete: $(du -h "$PREDEPLOY_DUMP" | cut -f1)"
            # Keep the five most recent pre-deploy dumps.
            # shellcheck disable=SC2012  # names are ours: timestamps, no whitespace
            { ls -1t backups/predeploy-*.dump 2>/dev/null || true; } | tail -n +6 | while read -r old; do
                rm -f "$old"
            done
        else
            rm -f "$PREDEPLOY_DUMP.partial"
            echo ""
            echo "!!! Could not dump the database, so not migrating without a way back."
            echo "!!! Deployment STOPPED at commit $DEPLOYING_COMMIT. Nothing was changed:"
            echo "!!! the previous container is still serving."
            exit 1
        fi
    else
        echo "    Database container is not running yet; no pre-migration dump."
    fi

    echo ""
    echo ">>> Applying migrations with the new image (old container still serving)..."
    if ! compose run --rm -T web python manage.py migrate --noinput </dev/null; then
        echo ""
        echo "!!! Migration FAILED at commit $DEPLOYING_COMMIT. The serving container was"
        echo "!!! NOT replaced: the site is still up on the previous code."
        echo "!!! Migrations that completed before the failing one remain applied."
        if [ -n "${PREDEPLOY_DUMP:-}" ]; then
            echo "!!! Database as it was before this deploy: $PREDEPLOY_DUMP"
        fi
        echo "!!! Do NOT run 'docker compose up' by hand until this is fixed — it would"
        echo "!!! start the new image, which would hit the same migration."
        rollback_hint
        exit 1
    fi
fi

# 5. Start the new containers.
#
# `up -d` recreates only what changed. The previous `down` first stopped every
# service — Postgres included — taking the whole site offline for the length of
# the build-and-start cycle for no reason.
echo ""
echo ">>> Starting new containers..."
compose up -d

# 6. Health gate.
#
# Poll the dependency-free liveness endpoint rather than sleeping blindly, so a
# container that fails to start fails the deploy instead of reporting success.
# Two minutes: the migrations are already applied, so this only has to cover
# the container starting and gunicorn booting — but it must never be the thing
# that calls a slow-but-fine start a failure.
#
# X-Forwarded-Proto is required, not decorative: production runs DEBUG=False,
# which turns on SECURE_SSL_REDIRECT, so a plain loopback request is 301'd to
# https://localhost:8000/ — where nothing speaks TLS. urlopen follows the
# redirect, the handshake fails, and every attempt looks like a dead app while
# the container is serving perfectly well. The compose healthcheck already
# sends this header; these scripts did not.
echo ""
echo ">>> Waiting for the app to become healthy..."
ready=0
for _ in $(seq 1 60); do
    if compose exec -T web \
        python -c 'import urllib.request,sys; r=urllib.request.Request("http://localhost:8000/healthz/", headers={"X-Forwarded-Proto": "https"}); sys.exit(0 if urllib.request.urlopen(r, timeout=3).status==200 else 1)' 2>/dev/null; then
        ready=1
        echo "    App is responding."
        break
    fi
    sleep 2
done

if [ "$ready" -ne 1 ]; then
    echo ""
    echo "!!! App did not become healthy. Recent logs:"
    compose logs --tail=50 web || true
    echo ""
    echo "!!! Deployment FAILED at commit $DEPLOYING_COMMIT."
    rollback_hint
    exit 1
fi

# 7. Scheduled jobs.
#
# The crontab is refreshed from scripts/install-cron.sh on every healthy
# deploy, so the schedule in production is the one in git. A failure here is
# loud but does not fail the deploy: the app is up and serving, and reporting
# the deploy as failed would send someone to roll back a healthy release.
echo ""
echo ">>> Refreshing scheduled jobs (crontab)..."
if ! bash scripts/install-cron.sh; then
    echo ""
    echo "!!! WARNING: the crontab was NOT updated (see above). The app is deployed"
    echo "!!! and healthy; scheduled jobs are as they were before this deploy."
fi

# 8. Old images.
#
# Every deploy leaves the previous image behind, untagged, and nothing ever
# removed them: on a small disk shared with Postgres that ends with the
# database out of space. Keep a week's worth — recent ones are the quick way
# back if the build itself is the problem — and remove older ones.
#
# Narrowed to images this compose project built (compose labels them): the
# box is shared, and other apps' images are not ours to prune. If the label is
# missing nothing matches and nothing is removed, which is the safe way to be
# wrong. The build cache has no such label, so only entries untouched for a
# fortnight go; losing cache costs a slower build, never anything else.
echo ""
echo ">>> Pruning old images..."
web_container="$(compose ps -q web 2>/dev/null | head -n 1 || true)"
project=""
if [ -n "$web_container" ]; then
    project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$web_container" 2>/dev/null || true)"
fi
if [ -n "$project" ]; then
    docker image prune -f \
        --filter "label=com.docker.compose.project=$project" \
        --filter "until=168h" || echo "    (image prune failed; not fatal)"
else
    echo "    Could not work out the compose project; no images pruned."
fi
docker builder prune -f --filter "until=336h" >/dev/null 2>&1 || true

# 9. Show status
echo ""
echo ">>> Service status:"
compose ps

# 10. Show recent logs
echo ""
echo ">>> Recent web logs:"
compose logs --tail=20 web

echo ""
echo "=================================================="
echo "  Deployment complete — $DEPLOYING_COMMIT"
echo "=================================================="
