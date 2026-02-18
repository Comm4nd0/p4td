#!/bin/bash
# Run this on the EC2 server to pull latest changes and rebuild the container
set -e

echo "=== Updating P4TD ==="

# Pull latest code
cd /home/ec2-user/p4td
git pull origin main

# Rebuild and restart container
echo "Stopping old container..."
docker stop p4td 2>/dev/null || true
docker rm p4td 2>/dev/null || true

echo "Building new image..."
docker build -t p4td:latest .

echo "Starting new container..."
docker run -d \
    --name p4td \
    --restart unless-stopped \
    --env-file /home/ec2-user/p4td/AWS-config.env \
    -p 8000:8000 \
    p4td:latest

# Wait for container to start
sleep 5

# Run migrations
echo "Running migrations..."
docker exec p4td python manage.py migrate --noinput

echo ""
echo "Container status:"
docker ps | grep p4td

echo ""
echo "=== Update Complete ==="
