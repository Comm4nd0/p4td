#!/bin/bash
# Initial setup for Hetzner CX22 server
# Run this ON the Hetzner server after transferring migration data
#
# Prerequisites:
#   - Fresh Ubuntu 22.04/24.04 on Hetzner CX22
#   - SSH access as root
#   - migration-data/ directory uploaded to /root/
#   - Git repo URL available
#
# Usage: ./scripts/setup-hetzner.sh

set -e

APP_DIR="/opt/p4td"
REPO_URL="https://github.com/Comm4nd0/p4td.git"
MIGRATION_DIR="/root/migration-data"

echo "=== P4TD: Hetzner Server Setup ==="
echo ""

# ============================================================================
# 1. Install Docker
# ============================================================================
echo "1. Installing Docker..."
if ! command -v docker &> /dev/null; then
    apt-get update
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    echo "   Docker installed."
else
    echo "   Docker already installed."
fi

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
docker compose -f docker-compose.prod.yml up -d db
echo "   Waiting for PostgreSQL to be ready..."
sleep 10

# Wait for postgres to accept connections
for i in $(seq 1 30); do
    if docker compose -f docker-compose.prod.yml exec -T db pg_isready -U "${RDS_USERNAME:-postgres}" > /dev/null 2>&1; then
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
    docker compose -f docker-compose.prod.yml exec -T db pg_restore \
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
    docker compose -f docker-compose.prod.yml up -d web
    sleep 5

    # Get the media volume mount path
    MEDIA_VOLUME=$(docker volume inspect p4td_media_data --format '{{ .Mountpoint }}' 2>/dev/null || echo "")
    if [ -n "$MEDIA_VOLUME" ]; then
        cp -r "$MIGRATION_DIR/media/"* "$MEDIA_VOLUME/" 2>/dev/null || true
        # Fix permissions for the appuser (UID 1000 in the container)
        chown -R 1000:1000 "$MEDIA_VOLUME/"
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
docker compose -f docker-compose.prod.yml up -d --build
sleep 10

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Services:"
docker compose -f docker-compose.prod.yml ps
echo ""
echo "Your app should be available at: https://9hj3.your-vhost.de"
echo ""
echo "Useful commands:"
echo "  cd $APP_DIR"
echo "  docker compose -f docker-compose.prod.yml logs -f        # View logs"
echo "  docker compose -f docker-compose.prod.yml exec web python manage.py createsuperuser  # Create admin"
echo "  docker compose -f docker-compose.prod.yml restart web    # Restart app"
