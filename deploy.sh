#!/bin/bash
# Deploy P4TD from a checkout *on the server*.
# Usage: ./deploy.sh [--skip-pull] [--no-cache]
#
# To deploy remotely from a laptop, use scripts/deploy-to-hetzner.sh instead —
# it does the same thing over SSH and records a rollback point.

set -euo pipefail

COMPOSE_FILE="docker-compose.prod.yml"

echo "=================================================="
echo "  Deploying Paws 4 Thought Dogs"
echo "=================================================="

# 0. Record a rollback point BEFORE anything changes.
#
# scripts/deploy-to-hetzner.sh has always done this; deploy.sh did not, which
# meant an automated deploy (see .github/workflows/deploy-backend.yml) had no
# recorded target to roll back to when it failed. Written before the pull so the
# commit captured is the one currently serving traffic.
PREV_COMMIT="$(git rev-parse HEAD)"
PREV_IMAGE="$(docker compose -f "$COMPOSE_FILE" images -q web 2>/dev/null || echo '')"
printf '%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PREV_COMMIT" "$PREV_IMAGE" >> .deploy-history
echo ""
echo ">>> Rollback point: $PREV_COMMIT (web image ${PREV_IMAGE:-none})"

# 1. Pull latest code.
#
# main only. This used to pull `development` first and then `main`, which
# merged unreviewed work-in-progress into production with no trace in
# `git log origin/main`. --ff-only means a diverged server checkout fails
# loudly here rather than silently creating a merge commit on the box.
if [[ "$*" != *"--skip-pull"* ]]; then
    echo ""
    echo ">>> Pulling latest code from main..."
    git fetch origin main
    git pull --ff-only origin main
else
    echo ""
    echo ">>> Skipping git pull (--skip-pull)"
fi

DEPLOYING_COMMIT="$(git rev-parse --short HEAD)"
echo ">>> Deploying commit: $DEPLOYING_COMMIT"

# 2. Build containers (includes collectstatic in Dockerfile)
echo ""
echo ">>> Building Docker images..."
if [[ "$*" == *"--no-cache"* ]]; then
    docker compose -f "$COMPOSE_FILE" build --no-cache
else
    docker compose -f "$COMPOSE_FILE" build
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

# 4. Start the new containers.
#
# `up -d` recreates only what changed. The previous `down` first stopped every
# service — Postgres included — taking the whole site offline for the length of
# the build-and-start cycle for no reason.
echo ""
echo ">>> Starting new containers..."
docker compose -f "$COMPOSE_FILE" up -d

# 5. Health gate.
#
# Poll the dependency-free liveness endpoint rather than sleeping blindly, so a
# container that crash-loops on a bad migration fails the deploy instead of
# reporting success. Mirrors scripts/deploy-to-hetzner.sh.
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
for _ in $(seq 1 30); do
    if docker compose -f "$COMPOSE_FILE" exec -T web \
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
    docker compose -f "$COMPOSE_FILE" logs --tail=50 web
    echo ""
    echo "!!! Deployment FAILED at commit $DEPLOYING_COMMIT."
    echo "!!! To roll back: git checkout $PREV_COMMIT && ./deploy.sh --skip-pull"
    exit 1
fi

# 6. Show status
echo ""
echo ">>> Service status:"
docker compose -f "$COMPOSE_FILE" ps

# 7. Show recent logs
echo ""
echo ">>> Recent web logs:"
docker compose -f "$COMPOSE_FILE" logs --tail=20 web

echo ""
echo "=================================================="
echo "  Deployment complete — $DEPLOYING_COMMIT"
echo "=================================================="
