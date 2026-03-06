# Shared Reverse Proxy (Reference)

These files are **templates** for the shared reverse proxy that lives outside any
individual app on the server (at `~/reverse-proxy/`).

The `setup-server.sh` script creates the actual proxy from scratch on the server.
The `setup-hetzner.sh` script (P4TD-specific) registers this app with the proxy.

**Do not deploy these files directly** — they are here for reference and versioning.

## Adding a new app to the server

1. Deploy your app's Docker Compose stack, joining the `caddy-net` network
2. Add a site block to `~/reverse-proxy/Caddyfile` on the server
3. If the app serves static files, mount its media volume in the proxy's `docker-compose.yml`
4. Reload Caddy:
   ```bash
   cd ~/reverse-proxy
   docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```
