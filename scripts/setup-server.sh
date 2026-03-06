#!/bin/bash
# One-time server setup for multi-app hosting on Hetzner
# This is server-level infrastructure — not specific to any app.
#
# What it does:
#   1. Installs Docker
#   2. Creates the shared caddy-net Docker network
#   3. Deploys the shared Caddy reverse proxy
#
# Prerequisites:
#   - Fresh Ubuntu/Debian server
#   - SSH access with sudo privileges
#
# Usage: bash setup-server.sh
#
# After running this, deploy individual apps with their own setup scripts
# (e.g. setup-p4td.sh)

set -e

PROXY_DIR="$HOME/reverse-proxy"

echo "=== Server Setup: Multi-App Hosting ==="
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
    sudo usermod -aG docker "$(whoami)"
    echo "   Docker installed."
    echo "   NOTE: You may need to log out and back in for docker group to take effect."
else
    echo "   Docker already installed."
fi

DOCKER="sudo docker"
DOCKER_COMPOSE="sudo docker compose"

# ============================================================================
# 2. Create shared Docker network
# ============================================================================
echo ""
echo "2. Creating shared Docker network..."
if ! $DOCKER network inspect caddy-net > /dev/null 2>&1; then
    $DOCKER network create caddy-net
    echo "   Created 'caddy-net' network."
else
    echo "   'caddy-net' network already exists."
fi

# ============================================================================
# 3. Set up reverse proxy
# ============================================================================
echo ""
echo "3. Setting up shared reverse proxy..."
mkdir -p "$PROXY_DIR"

# Create initial Caddyfile if it doesn't exist
if [ ! -f "$PROXY_DIR/Caddyfile" ]; then
    cat > "$PROXY_DIR/Caddyfile" << 'CADDYEOF'
# Shared Caddyfile for multi-app hosting
#
# Each app gets its own site block, routing by domain name.
# To add a new app:
#   1. Add a new site block below
#   2. Point the domain's DNS A record to this server's IP
#   3. Caddy will automatically provision HTTPS certificates via Let's Encrypt
#
# After editing, reload: docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
CADDYEOF
    echo "   Created empty Caddyfile at $PROXY_DIR/Caddyfile"
    echo "   You'll add app-specific blocks when deploying each app."
fi

# Create docker-compose for the proxy
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
    networks:
      - caddy-net

volumes:
  caddy_data:
  caddy_config:

networks:
  caddy-net:
    external: true
    name: caddy-net
COMPOSEEOF

echo "   Reverse proxy configured at $PROXY_DIR"

# ============================================================================
# 4. Start reverse proxy
# ============================================================================
echo ""
echo "4. Starting reverse proxy..."
cd "$PROXY_DIR"
$DOCKER_COMPOSE up -d

echo ""
echo "=== Server Setup Complete ==="
echo ""
echo "Reverse proxy is running at $PROXY_DIR"
echo ""
echo "Next steps:"
echo "  1. Deploy an app (e.g. bash setup-p4td.sh)"
echo "  2. The app's setup script will add its Caddy config and connect to caddy-net"
echo ""
echo "Useful commands:"
echo "  cd $PROXY_DIR"
echo "  sudo docker compose logs -f                                                  # Proxy logs"
echo "  sudo docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile    # Reload config"
