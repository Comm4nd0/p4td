#!/bin/bash
# Deploy P4TD on the server
# Usage: ./deploy.sh [--skip-pull] [--no-cache]

set -e

COMPOSE_FILE="docker-compose.prod.yml"

echo "=================================================="
echo "  Deploying Paws 4 Thought Dogs"
echo "=================================================="

# 1. Pull latest code
if [[ "$*" != *"--skip-pull"* ]]; then
    echo ""
    echo ">>> Pulling latest code from main..."
    git pull origin main
else
    echo ""
    echo ">>> Skipping git pull (--skip-pull)"
fi

# 2. Build containers (includes collectstatic in Dockerfile)
echo ""
echo ">>> Building Docker images..."
if [[ "$*" == *"--no-cache"* ]]; then
    docker compose -f "$COMPOSE_FILE" build --no-cache
else
    docker compose -f "$COMPOSE_FILE" build
fi

# 3. Stop old containers
echo ""
echo ">>> Stopping old containers..."
docker compose -f "$COMPOSE_FILE" down

# 4. Start new containers (runs migrate on startup)
echo ""
echo ">>> Starting new containers..."
docker compose -f "$COMPOSE_FILE" up -d

# 5. Wait for services to become healthy
echo ""
echo ">>> Waiting for services to start..."
sleep 5

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
echo "  Deployment complete"
echo "=================================================="
