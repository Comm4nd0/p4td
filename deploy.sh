#!/bin/bash
# Deploy P4TD on the server
# Usage: ./deploy.sh

set -e

echo "=== Deploying P4TD ==="

echo ">>> Pulling latest code..."
git pull origin main

echo ">>> Rebuilding and restarting containers..."
docker compose -f docker-compose.prod.yml up -d --build

echo ">>> Waiting for services to start..."
sleep 5

echo ">>> Service status:"
docker compose -f docker-compose.prod.yml ps

echo "=== Deployment complete ==="
