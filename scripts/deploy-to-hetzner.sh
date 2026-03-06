#!/bin/bash
# Deploy latest P4TD code to Hetzner server
# Only deploys this app — does not touch the shared reverse proxy or other apps.
#
# Usage: ./scripts/deploy-to-hetzner.sh

set -e

HETZNER_HOST="${HETZNER_HOST:-root@9hj3.your-vhost.de}"
APP_DIR="/root/p4td"
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

    echo '>>> Rebuilding and restarting P4TD...'
    docker compose -f docker-compose.prod.yml up -d --build

    echo '>>> Waiting for services...'
    sleep 10

    echo '>>> Running migrations...'
    docker compose -f docker-compose.prod.yml exec -T web python manage.py migrate --noinput

    echo '>>> Service status:'
    docker compose -f docker-compose.prod.yml ps

    echo '=== Deployment complete ==='
"

echo ""
echo "Done. P4TD is live."
