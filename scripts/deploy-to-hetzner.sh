#!/bin/bash
# Deploy latest code to Hetzner server
# Usage: ./scripts/deploy-to-hetzner.sh

set -e

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
    set -e
    cd $APP_DIR

    echo '>>> Pulling latest code...'
    git pull origin main

    echo '>>> Rebuilding and restarting...'
    docker compose -f docker-compose.prod.yml up -d --build

    echo '>>> Waiting for services...'
    sleep 10

    echo '>>> Running migrations...'
    docker compose -f docker-compose.prod.yml exec -T web python manage.py migrate --noinput

    echo '>>> Service status:'
    docker compose -f docker-compose.prod.yml ps

    echo '>>> Setting up media pruning cron job...'
    CRON_CMD='0 3 * * 0 cd $APP_DIR && docker compose -f docker-compose.prod.yml exec -T web python manage.py prune_feed_media --include-orphans >> /var/log/p4td-prune.log 2>&1'
    ( crontab -l 2>/dev/null | grep -v 'prune_feed_media'; echo \"\$CRON_CMD\" ) | crontab -

    echo '>>> Setting up vaccination reminder cron job...'
    VAX_CRON='0 8 * * * cd $APP_DIR && docker compose -f docker-compose.prod.yml exec -T web python manage.py send_vaccination_reminders >> /var/log/p4td-vaccinations.log 2>&1'
    ( crontab -l 2>/dev/null | grep -v 'send_vaccination_reminders'; echo \"\$VAX_CRON\" ) | crontab -

    echo '=== Deployment complete ==='
"

echo ""
echo "Done. App is live at: https://9hj3.your-vhost.de"
