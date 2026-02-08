#!/bin/bash
# Deploy script for p4td EC2 instance
# Usage: ./scripts/deploy.sh

set -e

EC2_HOST="46.137.83.83"
SSH_KEY="~/.ssh/p4td-key.pem"

echo "=== Deploying to EC2 ($EC2_HOST) ==="

ssh -i $SSH_KEY -o ConnectTimeout=60 ec2-user@$EC2_HOST '
  set -e
  cd /home/ec2-user/p4td

  echo ">>> Pulling latest code..."
  git fetch origin
  git reset --hard origin/main

  echo ">>> Stopping container..."
  docker stop p4td_prod 2>/dev/null || true
  docker rm p4td_prod 2>/dev/null || true

  echo ">>> Building Docker image..."
  docker build -t p4td_prod .

  echo ">>> Starting container..."
  docker run -d --name p4td_prod -p 8000:8000 \
    --env-file aws-config.env \
    -e CORS_ALLOW_ALL_ORIGINS=True \
    p4td_prod:latest

  echo ">>> Waiting for container to start..."
  sleep 5
  docker ps | grep p4td_prod

  echo ">>> Running migrations..."
  docker exec p4td_prod python manage.py migrate --noinput

  echo "=== DEPLOYMENT COMPLETE ==="
'
