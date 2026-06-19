# Production deployment (Hetzner)

How the **p4td backend** actually runs in production. Read this before changing
`docker-compose.prod.yml`, the `Dockerfile`, the `Caddyfile`, or anything that
touches serving/networking — several "obvious" simplifications break this setup
because it is **not** a self-contained stack.

> The committed `Caddyfile` is a **reference only**. The live Caddy config is a
> separate file on the server (see below).

## The big picture

The host is a **single Hetzner box running many independent app stacks** (p4td,
plus several other sites), each its own `docker compose` project, all fronted by
**one shared Caddy container**.

```
Internet ──443──> caddy-caddy-1 (separate container, network: caddy_default)
                        │  (per-site config in /root/caddy/Caddyfile)
                        │  TLS terminated here; sets X-Forwarded-Proto=https
                        ▼  reverse_proxy 172.17.0.1:8000   (the HOST's docker0 gateway)
                  p4td-web-1 (gunicorn, network: p4td_default)
                        │  port published on the host: 172.17.0.1:8000:8000
                        └─ talks to p4td-db-1 (Postgres) on p4td_default
```

Key consequence: **Caddy and the p4td app are on different Docker networks.**
Caddy cannot reach the app by container name — it reaches it via the **host
port** (`172.17.0.1:8000`, the docker0 bridge gateway).

## The p4td stack

- **Repo on server:** `/root/p4td` (`~/p4td`), tracking the `main` branch.
- **Compose file:** `docker-compose.prod.yml` → services `db` (Postgres 15,
  named volume `postgres_data`) and `web` (gunicorn).
- **App port:** published as `172.17.0.1:8000:8000` — reachable by Caddy via the
  docker0 gateway, NOT on the public interface. (There is currently **no `ufw`
  firewall**, so do not bind this to `0.0.0.0`.)
- **Media:** bind-mounted `./media` (= `/root/p4td/media`) → `/app/media`.
  Caddy serves `/media/*` from `/srv/p4td-media`, which is that **same host
  directory** (`/root/p4td/media`) mounted into the Caddy container.
- **Runtime config:** from `.env` (via `env_file`) — `DJANGO_SECRET_KEY`,
  `DJANGO_DEBUG=False`, `RDS_*`, etc. `DJANGO_DEBUG` is **not** baked into the
  image, so prod is `DEBUG=False` unless `.env` says otherwise.

## Caddy (the live config)

- Container `caddy-caddy-1`, compose project at **`/root/caddy`**.
- Live config: **`/root/caddy/Caddyfile`** (mounted to `/etc/caddy/Caddyfile`).
- The p4td block (mirror of the committed `Caddyfile`):
  ```
  paws4thoughtdogs.com, www.paws4thoughtdogs.com {
      handle_path /media/* { root * /srv/p4td-media; file_server }
      reverse_proxy 172.17.0.1:8000
      encode gzip
  }
  ```
- TLS certs are auto-provisioned by Caddy. To change routing, edit
  `/root/caddy/Caddyfile` and reload Caddy (`docker exec caddy-caddy-1 caddy
  reload --config /etc/caddy/Caddyfile`), **not** the committed `Caddyfile`.

## Deploying

```bash
cd ~/p4td && ./deploy.sh         # git pull + docker build + migrate + restart
```

For a **compose-only** change (the command, ports, healthcheck, volumes — no
Python/Dockerfile change) you don't need a rebuild:

```bash
cd ~/p4td && git pull --ff-only origin main && \
  docker compose -f docker-compose.prod.yml up -d
```

Quick health checks after deploy:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://paws4thoughtdogs.com/healthz/   # 200
curl -s -o /dev/null -w '%{http_code}\n' https://paws4thoughtdogs.com/api/dogs/  # 401 (reachable + auth)
docker inspect -f '{{.State.Health.Status}} restarts={{.RestartCount}}' p4td-web-1
docker logs p4td-web-1 --tail 20
```

## Do-not-break list (these have each broken prod before)

1. **Keep the gunicorn `command` on one logical line / list form.** A YAML `>`
   folded scalar with extra-indented continuation lines splits the command
   across shell lines → `No application module specified` crash-loop.
2. **Keep the app port published** (`172.17.0.1:8000:8000`). Caddy reaches the
   app only via the host port; removing it → **502**.
3. **Keep media as a host bind-mount** matching Caddy's `/srv/p4td-media`
   (`/root/p4td/media`). A Docker named volume → Caddy serves an empty dir →
   broken images.
4. **`requirements-prod.txt` does `-r requirements.txt`,** so the Dockerfile must
   `COPY` **both** files before `pip install`.
5. **`SECURE_SSL_REDIRECT=True`** (prod) relies on Caddy sending
   `X-Forwarded-Proto=https` (it does). The loopback container healthcheck sends
   that header explicitly so it isn't 301'd to an https port nothing serves.

## One-time / periodic ops

See **`IMPROVEMENTS.md` → Manual deploy steps**: nightly `pg_dump` backups
shipped off-box, the `P4TD_CRON_HEARTBEAT_URL` for cron alerting,
`CONTACT_INQUIRY_EMAIL`, and a note that the B15/B16 constraint migrations need
clean data first. Backend deploys are manual (no auto-CD).
