#!/usr/bin/env bash
# Deploy latest code to Hetzner server
# Usage: ./scripts/deploy-to-hetzner.sh

set -euo pipefail

HETZNER_HOST="${HETZNER_HOST:-root@9hj3.your-vhost.de}"
APP_DIR="/opt/p4td"
SSH_KEY="${SSH_KEY:-}"

# Build SSH command
SSH_CMD="ssh"
if [ -n "$SSH_KEY" ]; then
    SSH_CMD="ssh -i $SSH_KEY"
fi

echo "=== Deploying P4TD to Hetzner ==="
echo "Host: $HETZNER_HOST"
echo ""

$SSH_CMD "$HETZNER_HOST" "
    set -eo pipefail
    cd $APP_DIR

    echo '>>> Recording rollback point...'
    # Record the currently-deployed commit and the current web image id so a
    # failed deploy can be reverted manually. To roll back:
    #   git checkout <PREV_COMMIT> && docker compose -f docker-compose.prod.yml up -d --build
    # (or re-tag/run the saved image id below if the build is the problem).
    PREV_COMMIT=\$(git rev-parse HEAD)
    PREV_IMAGE=\$(docker compose -f docker-compose.prod.yml images -q web 2>/dev/null || echo '')
    echo \"    Previous commit: \$PREV_COMMIT\"
    echo \"    Previous web image: \$PREV_IMAGE\"
    printf '%s\t%s\t%s\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"\$PREV_COMMIT\" \"\$PREV_IMAGE\" >> $APP_DIR/.deploy-history

    echo '>>> Pulling latest code...'
    git pull origin main

    echo '>>> Rebuilding and restarting...'
    docker compose -f docker-compose.prod.yml up -d --build

    echo '>>> Waiting for app to become healthy...'
    # Poll the dependency-free liveness endpoint instead of a blind sleep, so we
    # only migrate once the new container is actually serving requests.
    ready=0
    for i in \$(seq 1 30); do
        if docker compose -f docker-compose.prod.yml exec -T web \
            python -c 'import urllib.request,sys; sys.exit(0 if urllib.request.urlopen(\"http://localhost:8000/healthz/\", timeout=3).status==200 else 1)' 2>/dev/null; then
            ready=1
            echo '    App is responding.'
            break
        fi
        sleep 2
    done
    if [ \"\$ready\" -ne 1 ]; then
        echo '    ERROR: app did not become healthy in time. Aborting deploy.' >&2
        docker compose -f docker-compose.prod.yml logs --tail=40 web >&2 || true
        exit 1
    fi

    echo '>>> Running migrations...'
    docker compose -f docker-compose.prod.yml exec -T web python manage.py migrate --noinput

    echo '>>> Post-deploy health check...'
    # Fail loudly on a non-200 so a broken deploy does not look successful.
    if ! docker compose -f docker-compose.prod.yml exec -T web \
        python -c 'import urllib.request,sys; sys.exit(0 if urllib.request.urlopen(\"http://localhost:8000/healthz/\", timeout=5).status==200 else 1)'; then
        echo '    ERROR: /healthz/ did not return 200 after migrate.' >&2
        echo \"    Roll back with: git checkout \$PREV_COMMIT && docker compose -f docker-compose.prod.yml up -d --build\" >&2
        exit 1
    fi
    echo '    Health check passed.'

    echo '>>> Service status:'
    docker compose -f docker-compose.prod.yml ps

    echo '>>> Setting up media pruning cron job...'
    CRON_CMD='0 3 * * 0 cd $APP_DIR && docker compose -f docker-compose.prod.yml exec -T web python manage.py prune_feed_media --include-orphans >> /var/log/p4td-prune.log 2>&1'
    ( crontab -l 2>/dev/null | grep -v 'prune_feed_media'; echo \"\$CRON_CMD\" ) | crontab -

    echo '>>> Setting up vaccination reminder cron job...'
    VAX_CRON='0 8 * * * cd $APP_DIR && docker compose -f docker-compose.prod.yml exec -T web python manage.py send_vaccination_reminders >> /var/log/p4td-vaccinations.log 2>&1'
    ( crontab -l 2>/dev/null | grep -v 'send_vaccination_reminders'; echo \"\$VAX_CRON\" ) | crontab -

    echo '>>> Setting up fleet reminder cron job...'
    FLEET_CRON='5 8 * * * cd $APP_DIR && docker compose -f docker-compose.prod.yml exec -T web python manage.py send_fleet_reminders >> /var/log/p4td-fleet.log 2>&1'
    ( crontab -l 2>/dev/null | grep -v 'send_fleet_reminders'; echo \"\$FLEET_CRON\" ) | crontab -

    echo '=== Deployment complete ==='
"

echo ""
echo "Done. App is live at: https://9hj3.your-vhost.de"
