#!/bin/bash
set -e

echo "=== P4TD Local Update ==="

cd "$(dirname "$0")/.."

echo "1. Pulling latest code..."
git pull origin main

echo ""
echo "2. Rebuilding containers..."
docker-compose down
docker-compose up --build -d

echo ""
echo "3. Waiting for database..."
sleep 5

echo ""
echo "4. Running migrations..."
docker-compose exec web python manage.py migrate --noinput

echo ""
echo "=== Local Update Complete ==="
echo "API running at: http://localhost:8000"
