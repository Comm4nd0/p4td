#!/bin/bash
set -e

echo "=== P4TD Local Update ==="

cd "$(dirname "$0")/.."

# Detect compose command
if command -v docker-compose &> /dev/null; then
    DC="docker-compose"
elif docker compose version &> /dev/null; then
    DC="docker compose"
else
    echo "Error: Neither 'docker-compose' nor 'docker compose' found."
    echo "Install with: pip install docker-compose"
    exit 1
fi

echo "Using: $DC"

echo ""
echo "1. Pulling latest code..."
git pull origin main

echo ""
echo "2. Rebuilding containers..."
$DC down
$DC up --build -d

echo ""
echo "3. Waiting for database..."
sleep 5

echo ""
echo "4. Running migrations..."
$DC exec web python manage.py migrate --noinput

echo ""
echo "=== Local Update Complete ==="
echo "API running at: http://localhost:8000"
