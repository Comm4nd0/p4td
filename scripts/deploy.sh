#!/bin/bash
set -e
SSH_KEY="~/.ssh/p4td-key.pem"
EC2_HOST="46.137.83.83"

echo "=== TEXT-BASED DEPLOYMENT ==="

# Read local config files to avoid hardcoding secrets
if [ ! -f "p4td-firebase-adminsdk.json" ] || [ ! -f "aws-config.env" ]; then
    echo "Error: Configuration files not found in current directory."
    exit 1
fi

FIREBASE_KEY=$(cat p4td-firebase-adminsdk.json)
AWS_CONFIG=$(cat aws-config.env)

# Use a single SSH session to write files and execute commands
ssh -i $SSH_KEY -o ConnectTimeout=60 ec2-user@$EC2_HOST "
  set -e
  mkdir -p /home/ec2-user/p4td
  cd /home/ec2-user/p4td

  echo '>>> [REMOTE] Writing aws-config.env...'
  cat > aws-config.env <<EOF
$AWS_CONFIG
EOF

  echo '>>> [REMOTE] Writing p4td-firebase-adminsdk.json...'
  cat > p4td-firebase-adminsdk.json <<EOF
$FIREBASE_KEY
EOF

  echo '>>> [REMOTE] Files written. Pulling latest code...'
  git fetch origin
  git reset --hard origin/main

  echo '>>> [REMOTE] Stopping old container...'
  docker stop p4td_prod 2>/dev/null || true
  docker rm p4td_prod 2>/dev/null || true

  echo '>>> [REMOTE] Building Docker image...'
  docker build -t p4td_prod .

  echo '>>> [REMOTE] Starting container...'
  docker run -d --name p4td_prod -p 8000:8000 \
    --env-file aws-config.env \
    -e CORS_ALLOW_ALL_ORIGINS=True \
    p4td_prod:latest

  echo '>>> [REMOTE] Waiting for container health...'
  sleep 5
  docker ps | grep p4td_prod

  echo '>>> [REMOTE] Running migrations...'
  docker exec p4td_prod python manage.py migrate --noinput
  
  echo '=== [REMOTE] DEPLOYMENT COMPLETE ==='
"
