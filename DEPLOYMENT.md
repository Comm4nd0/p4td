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
- **Private media:** bind-mounted `./private-media` (= `/root/p4td/private-media`)
  → `/app/private-media`. Vaccination certificates. **Not** mounted into Caddy
  and must never be: nothing serves this directory, the API's gated download
  view is the only way to a file (`api/certificates.py`). Created by the
  container on first upload; `chown 1000:1000` it if you create it by hand.
  `scripts/backup-db.sh` archives it alongside every database dump.
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

### Automatic (default)

**A successful `Backend CI` run on `main` deploys production automatically** via
`.github/workflows/deploy-backend.yml`. It SSHes to the server and runs
`./deploy.sh`, then checks `https://paws4thoughtdogs.com/healthz/` through Caddy
— so both the container and the public path are verified before the run is
green.

It is triggered by *CI completing*, not by the push, so nothing reaches
production until the suite is green. The consequence: a change that doesn't
trigger `Backend CI` never deploys, which is why that workflow's path filters
include `Dockerfile`, `docker-compose.prod.yml` and `deploy.sh`. Add any new
file that changes production behaviour to those filters too.

Required repository secrets (Settings > Secrets and variables > Actions):

| Secret | What |
|---|---|
| `HETZNER_HOST` | Hostname or IP of the box (no `user@`) |
| `HETZNER_USER` | SSH user — `root` |
| `HETZNER_SSH_KEY` | Private half of a **dedicated deploy keypair**, whole file including header/footer |
| `HETZNER_KNOWN_HOSTS` | `<host> ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC8+WpGRLNF0kJsdZ3wa9PHlyiIPsVK7+JheD8N47nY5` |

Optional repo *variable* `HETZNER_APP_DIR` overrides the `/root/p4td` default.

Generate the keypair and authorise it (do **not** reuse a personal key):

```bash
ssh-keygen -t ed25519 -f p4td-deploy -C 'github-actions-deploy' -N ''
ssh-copy-id -i p4td-deploy.pub root@<host>   # then paste p4td-deploy into HETZNER_SSH_KEY
```

> **Migrations run unattended.** The container's `command` runs
> `migrate --noinput` on start, so an automatic deploy applies migrations with
> nobody watching. To require a human first, add required reviewers to the
> `production` environment in the repo settings — the workflow already targets
> it, so that is the only change needed.

### Manual

Still available, and the right choice for a large catch-up deploy or after a
rollback:

```bash
# On the server:
cd ~/p4td && ./deploy.sh                 # pull main + build + restart + health gate

# From a laptop (does the above over SSH, and records a rollback point):
./scripts/deploy-to-hetzner.sh
```

Both pull **`main` only**, with `--ff-only`, and both poll `/healthz/` before
reporting success — a container that crash-loops on a bad migration fails the
deploy rather than completing silently. `deploy.sh` prints the commit it
deployed; `deploy-to-hetzner.sh` also appends the previous commit and image id
to `.deploy-history` so a rollback target is always recorded.

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
   **Never widen Caddy's root to cover `private-media/`** (or mount it into
   the Caddy container at all): that would publish every vaccination
   certificate — vet paperwork with the owner's name and address on it — to
   anyone with the link.
4. **`requirements-prod.txt` does `-r requirements.txt`,** so the Dockerfile must
   `COPY` **both** files before `pip install`.
5. **`SECURE_SSL_REDIRECT=True`** (prod) relies on Caddy sending
   `X-Forwarded-Proto=https` (it does). The loopback container healthcheck sends
   that header explicitly so it isn't 301'd to an https port nothing serves.

## One-time / periodic ops

See **`IMPROVEMENTS.md` → Manual deploy steps**: nightly `pg_dump` backups
shipped off-box, the `P4TD_CRON_HEARTBEAT_URL` for cron alerting,
`CONTACT_INQUIRY_EMAIL`, and a note that the B15/B16 constraint migrations need
clean data first.
