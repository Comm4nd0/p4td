#!/bin/bash
# Initial setup for Hetzner CX22 server
# Run this ON the Hetzner server after transferring migration data
#
# Prerequisites:
#   - Fresh Ubuntu/Debian on Hetzner CX22
#   - SSH access (will use sudo for privileged operations)
#   - migration-data/ directory uploaded to ~/migration-data
#   - Git repo URL available
#
# Usage: bash setup-hetzner.sh

set -e

APP_DIR="$HOME/p4td"
REPO_URL="https://github.com/Comm4nd0/p4td.git"
MIGRATION_DIR="$HOME/migration-data"

echo "=== P4TD: Hetzner Server Setup ==="
echo "User: $(whoami)"
echo "Home: $HOME"
echo ""

# ============================================================================
# 1. Install Docker
# ============================================================================
echo "1. Installing Docker..."
if ! command -v docker &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    # Add current user to docker group so we don't need sudo for docker commands
    sudo usermod -aG docker "$(whoami)"
    echo "   Docker installed."
    echo "   NOTE: You may need to log out and back in for docker group to take effect."
    echo "   Or run: newgrp docker"
else
    echo "   Docker already installed."
fi

# Use sudo for docker commands in case the group hasn't taken effect yet
DOCKER="sudo docker"
DOCKER_COMPOSE="sudo docker compose"

# ============================================================================
# 2. Clone repo
# ============================================================================
echo ""
echo "2. Setting up application..."
if [ -d "$APP_DIR" ]; then
    echo "   $APP_DIR already exists, pulling latest..."
    cd "$APP_DIR"
    git pull origin main
else
    git clone "$REPO_URL" "$APP_DIR"
    cd "$APP_DIR"
fi

# ============================================================================
# 3. Create .env file
# ============================================================================
echo ""
echo "3. Setting up environment..."
if [ ! -f "$APP_DIR/.env" ]; then
    DJANGO_SECRET_KEY=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 50)
    DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

    cat > "$APP_DIR/.env" << EOF
DOMAIN_NAME=9hj3.your-vhost.de
DJANGO_SECRET_KEY=$DJANGO_SECRET_KEY
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=9hj3.your-vhost.de,localhost,127.0.0.1
RDS_DB_NAME=p4td
RDS_USERNAME=postgres
RDS_PASSWORD=$DB_PASSWORD
RDS_PORT=5432
CORS_ALLOWED_ORIGINS=https://9hj3.your-vhost.de
CORS_ALLOW_ALL_ORIGINS=False
EOF
    echo "   .env created with generated secrets."
    echo "   IMPORTANT: Review and edit $APP_DIR/.env if needed."
else
    echo "   .env already exists, skipping."
fi

# Source .env for DB password
source "$APP_DIR/.env"

# ============================================================================
# 4. Start database first
# ============================================================================
echo ""
echo "4. Starting database..."
cd "$APP_DIR"
$DOCKER_COMPOSE -f docker-compose.prod.yml up -d db
echo "   Waiting for PostgreSQL to be ready..."
sleep 10

# Wait for postgres to accept connections
for i in $(seq 1 30); do
    if $DOCKER_COMPOSE -f docker-compose.prod.yml exec -T db pg_isready -U "${RDS_USERNAME:-postgres}" > /dev/null 2>&1; then
        echo "   PostgreSQL is ready."
        break
    fi
    sleep 2
done

# ============================================================================
# 5. Import database dump
# ============================================================================
echo ""
echo "5. Importing database dump..."
if [ -f "$MIGRATION_DIR/db-dump.sql" ]; then
    $DOCKER_COMPOSE -f docker-compose.prod.yml exec -T db pg_restore \
        -U "${RDS_USERNAME:-postgres}" \
        -d "${RDS_DB_NAME:-p4td}" \
        --no-owner \
        --no-privileges \
        --if-exists \
        --clean \
        < "$MIGRATION_DIR/db-dump.sql" || true
    echo "   Database imported."
else
    echo "   No database dump found at $MIGRATION_DIR/db-dump.sql"
    echo "   The database will be empty (migrations will create tables)."
fi

# ============================================================================
# 6. Copy media files
# ============================================================================
echo ""
echo "6. Copying media files..."
if [ -d "$MIGRATION_DIR/media" ]; then
    # Start web temporarily to create the volume, then copy media into it
    $DOCKER_COMPOSE -f docker-compose.prod.yml up -d web
    sleep 5

    # Get the media volume mount path
    MEDIA_VOLUME=$($DOCKER volume inspect p4td_media_data --format '{{ .Mountpoint }}' 2>/dev/null || echo "")
    if [ -n "$MEDIA_VOLUME" ]; then
        sudo cp -r "$MIGRATION_DIR/media/"* "$MEDIA_VOLUME/" 2>/dev/null || true
        # Fix permissions for the appuser (UID 1000 in the container)
        sudo chown -R 1000:1000 "$MEDIA_VOLUME/"
        echo "   Media files copied to volume."
    else
        echo "   Warning: Could not find media volume. Copy media manually."
    fi
else
    echo "   No media directory found at $MIGRATION_DIR/media"
fi

# ============================================================================
# 7. Start full stack
# ============================================================================
echo ""
echo "7. Starting full stack..."
$DOCKER_COMPOSE -f docker-compose.prod.yml up -d --build
sleep 10

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Services:"
$DOCKER_COMPOSE -f docker-compose.prod.yml ps
echo ""
echo "Your app should be available at: https://9hj3.your-vhost.de"
echo ""
echo "Useful commands:"
echo "  cd $APP_DIR"
echo "  sudo docker compose -f docker-compose.prod.yml logs -f        # View logs"
echo "  sudo docker compose -f docker-compose.prod.yml exec web python manage.py createsuperuser  # Create admin"
echo "  sudo docker compose -f docker-compose.prod.yml restart web    # Restart app"
