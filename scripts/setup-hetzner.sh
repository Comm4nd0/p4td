#!/bin/bash
# P4TD app setup for Hetzner server (multi-app architecture)
# Run this ON the server AFTER setup-server.sh has been run.
#
# Prerequisites:
#   - setup-server.sh has been run (Docker installed, caddy-net exists, proxy running)
#   - Optional: migration-data/ directory uploaded to ~/migration-data
#
# Usage: bash setup-hetzner.sh

set -e

APP_DIR="$HOME/p4td"
PROXY_DIR="$HOME/reverse-proxy"
REPO_URL="https://github.com/Comm4nd0/p4td.git"
MIGRATION_DIR="$HOME/migration-data"

DOCKER="sudo docker"
DOCKER_COMPOSE="sudo docker compose"

echo "=== P4TD: App Setup ==="
echo ""

# ============================================================================
# 1. Verify server setup
# ============================================================================
echo "1. Checking prerequisites..."
if ! $DOCKER network inspect caddy-net > /dev/null 2>&1; then
    echo "   ERROR: caddy-net network not found. Run setup-server.sh first."
    exit 1
fi
echo "   caddy-net network exists."

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

source "$APP_DIR/.env"

# ============================================================================
# 4. Start database
# ============================================================================
echo ""
echo "4. Starting database..."
cd "$APP_DIR"
$DOCKER_COMPOSE -f docker-compose.prod.yml up -d db
echo "   Waiting for PostgreSQL to be ready..."
sleep 10

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
    $DOCKER_COMPOSE -f docker-compose.prod.yml up -d web
    sleep 5

    MEDIA_VOLUME=$($DOCKER volume inspect p4td_media_data --format '{{ .Mountpoint }}' 2>/dev/null || echo "")
    if [ -n "$MEDIA_VOLUME" ]; then
        sudo cp -r "$MIGRATION_DIR/media/"* "$MEDIA_VOLUME/" 2>/dev/null || true
        sudo chown -R 1000:1000 "$MEDIA_VOLUME/"
        echo "   Media files copied to volume."
    else
        echo "   Warning: Could not find media volume. Copy media manually."
    fi
else
    echo "   No media directory found at $MIGRATION_DIR/media"
fi

# ============================================================================
# 7. Start app stack
# ============================================================================
echo ""
echo "7. Starting P4TD app stack..."
cd "$APP_DIR"
$DOCKER_COMPOSE -f docker-compose.prod.yml up -d --build

# ============================================================================
# 8. Register with reverse proxy
# ============================================================================
echo ""
echo "8. Registering with reverse proxy..."

# Add P4TD's media volume to the proxy's docker-compose
# and add the Caddy site block
DOMAIN="${DOMAIN_NAME:-localhost}"

# Append P4TD site block to Caddyfile if not already present
if ! grep -q "p4td-web" "$PROXY_DIR/Caddyfile" 2>/dev/null; then
    cat >> "$PROXY_DIR/Caddyfile" << CADDYEOF

# ---------------------------------------------------------------------------
# P4TD (Paws4Thought Dogs)
# ---------------------------------------------------------------------------
${DOMAIN} {
    reverse_proxy p4td-web:8000

    handle_path /media/* {
        root * /srv/p4td/media
        file_server
    }

    encode gzip
}
CADDYEOF
    echo "   Added P4TD site block to Caddyfile."
else
    echo "   P4TD already configured in Caddyfile."
fi

# Add media volume mount to proxy if not already present
cd "$PROXY_DIR"
if ! grep -q "p4td_media" "$PROXY_DIR/docker-compose.yml" 2>/dev/null; then
    # Recreate proxy compose with the p4td media volume
    cat > "$PROXY_DIR/docker-compose.yml" << 'COMPOSEEOF'
# Shared reverse proxy for multi-app hosting
services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
      - p4td_media:/srv/p4td/media:ro
    networks:
      - caddy-net

volumes:
  caddy_data:
  caddy_config:
  p4td_media:
    external: true
    name: p4td_media_data

networks:
  caddy-net:
    external: true
    name: caddy-net
COMPOSEEOF
    echo "   Added P4TD media volume to proxy."
fi

# Restart proxy to pick up changes
$DOCKER_COMPOSE up -d
sleep 5

echo ""
echo "=== P4TD Setup Complete ==="
echo ""
echo "Services:"
cd "$APP_DIR"
$DOCKER_COMPOSE -f docker-compose.prod.yml ps
echo ""
echo "Your app should be available at: https://${DOMAIN}"
echo ""
echo "Useful commands:"
echo "  cd $APP_DIR"
echo "  sudo docker compose -f docker-compose.prod.yml logs -f        # P4TD logs"
echo "  sudo docker compose -f docker-compose.prod.yml exec web python manage.py createsuperuser"
