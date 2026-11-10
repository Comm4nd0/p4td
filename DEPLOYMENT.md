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
  view is the only way to a file (`api/certificates.py`). The container runs
  as uid 1000 and cannot create this directory itself: if it is missing when
  the container starts, the Docker daemon creates it as root:root 755 and
  every upload then 500s with "Permission denied". `deploy.sh` therefore
  creates it and `chown 1000:1000`s it before `up -d`; do the same if you ever
  create it by hand.
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
- **Request size cap — not yet in the live config.** The committed `Caddyfile`
  now carries `request_body { max_size 250MB }` in the p4td block; the live
  one has no cap until someone adds the same three lines to
  `/root/caddy/Caddyfile` and reloads (see [Owner's to-do](#owners-to-do)).
  Without it Caddy passes a body of any size through and Django spools it to
  disk before checking anything, on the disk Postgres shares. 250 MB is the
  app's largest upload (a 200 MB video) plus headroom.

## Deploying

> **Production changes only between 22:00 and 06:00 UK time, unless given
> explicit permission.** The site and app have real customers and staff on them
> from 2026-09, and the business day runs well beyond opening hours, so the
> safe window is overnight, every day of the week. Outside it, do not do
> anything that changes what production serves unless Marco has explicitly said
> so for that specific change: no push or merge to `main` that touches the
> backend or website (a green `Backend CI` on `main` deploys on its own), no
> `deploy.sh` or `scripts/deploy-to-hetzner.sh`, no edits, restarts or
> migrations on the server over SSH. Read-only work on the server (logs,
> queries) is fine. Commit and get everything ready during the day, and push
> inside the window or when told to. A permission given for one change does not
> carry over to the next.

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

The workflow deploys only for a **push to this repository's `main`**: the gate
checks the triggering run's event and repository as well as its branch name,
because a pull request from a fork's own `main` otherwise looks the same.

> **Migrations run unattended.** `deploy.sh` applies them with nobody
> watching. To require a human first, add required reviewers to the
> `production` environment in the repo settings — the workflow already targets
> it, so that is the only change needed.

### What `deploy.sh` does, and what each failure leaves behind

1. Records the commit currently serving in `.deploy-history`, pulls `main`
   (`--ff-only`), builds the image. *Fails here: nothing has changed.*
2. Asks the new image whether migrations are pending (`migrate --check` in a
   throwaway container). If so it **dumps the database** to
   `backups/predeploy-<stamp>-<commit>.dump` (the five newest are kept) and
   **applies the migrations from a throwaway container while the old one is
   still serving**.
   *Dump fails: stops, nothing changed. Migration fails: stops, and the site
   is still up on the old code* — it used to be down until someone rolled
   back, because the old container had already been replaced. Migrations that
   completed before the failing one stay applied; the dump is the way back if
   one of them is the problem (`pg_restore --clean --if-exists`).
3. Swaps the serving container (`up -d`) and polls `/healthz/` for up to two
   minutes. *Fails here: the new container is up but unhealthy; roll back with
   the printed command.*
4. Refreshes the crontab (`scripts/install-cron.sh`) and prunes this project's
   untagged images older than a week. *Fails here: a warning only — the app is
   deployed and healthy.*

Because the migration lands a few seconds before the code that expects it, the
old code briefly runs against the new schema. Write migrations accordingly:
add in one release, remove in a later one. A migration that drops or renames
something the running code still reads will error for those seconds.

After a failed migration, do **not** run `docker compose up` by hand: the
image tagged `latest` is the new one, and starting it would run the same
migration as the serving container.

### Manual

Still available, and the right choice for a large catch-up deploy or after a
rollback:

```bash
# On the server:
cd ~/p4td && ./deploy.sh                 # pull main + build + restart + health gate

# From a laptop (runs the same ./deploy.sh over SSH):
HETZNER_HOST=root@<server> ./scripts/deploy-to-hetzner.sh
```

There is one deploy path: `deploy-to-hetzner.sh` is a thin wrapper that SSHes
in and runs `./deploy.sh`, so both pull **`main` only**, with `--ff-only`,
record the rollback point in `.deploy-history`, and health-gate before
reporting success. The server's address is not in the repository (it is
public); pass it as `HETZNER_HOST` or the first argument.

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

## Scheduled jobs

`deploy.sh` installs the crontab from `scripts/install-cron.sh` after every
healthy deploy, so the schedule in production is the one in git. To add or
move a job, edit the table in that script — not the crontab, which is
overwritten. (It used to be installed only by the laptop script, so a job
added in a commit stayed unscheduled until someone deployed by hand.)

- p4td's entries sit between two marker lines; only that block is rewritten.
  The unmarked entries the old laptop script installed are recognised (this
  checkout's path plus a p4td command) and replaced on the first run. Other
  apps' lines are never touched, the previous crontab is saved to
  `backups/crontab-<stamp>.txt`, and if the crontab cannot be read nothing is
  written.
- **Times are UK local time.** Each line fires every hour and
  `scripts/run-cron.sh` runs the job only in the London hour it names, so "8am"
  is 8am in summer too (the host clock is UTC; these ran an hour late all
  summer).
- **A deploy in progress no longer loses a job.** `run-cron.sh` waits up to
  20 minutes for the web container, then runs the command once.
- New with this: the nightly backup (02:30) and `prune_device_tokens`
  (Sundays 03:20). `prune_auth_tokens` is deliberately **not** scheduled: a
  login token is never refreshed, so a weekly run would sign every customer
  out once their token turned 180 days old. Run it by hand, or schedule it,
  only once that is a decision.
- Logs: `/var/log/p4td-<name>.log`, as before. Nothing rotates them.
- Preview without installing: `crontab -l | bash scripts/install-cron.sh --print`.

**The reminder commands refuse to run without Firebase.** If the service
account key cannot be loaded they exit non-zero before marking anything sent
and without pinging the heartbeat; a reminder FCM refuses is un-marked and
tried again on the next run. (They used to mark every one-shot reminder sent,
send nothing, and report success.) Set `P4TD_CRON_ALLOW_NO_PUSH=1` only on a
box that genuinely has no Firebase.

## Backups

`scripts/backup-db.sh`, nightly at 02:30 UK time, into `/root/p4td/backups/`
(root-only): a `pg_dump`, a tarball of `private-media/`, and a hard-link
snapshot of `media/` (`backups/media-snapshots/<stamp>/` — no extra space for
unchanged files; keeps a deleted or wrongly-swept photo for a week). Seven of
each are kept. Everything is written under a `.partial` name and renamed when
complete, so a failed run never leaves — or counts as — a backup.

**All of that is on the same disk as the data.** Nothing leaves the server
until `BACKUP_OFFBOX_CMD` is set in `/root/p4td/.env`; the script says so on
every run until it is. See the header of `scripts/backup-db.sh` for the
variables it exports and an rclone example. A failed off-box copy fails the
run.

Restore: `docker compose -f docker-compose.prod.yml exec -T db pg_restore -U
"$RDS_USERNAME" -d "$RDS_DB_NAME" --clean --if-exists < backups/p4td-<stamp>.dump`.
**No restore has been rehearsed** — do one onto a scratch database before
relying on these.

## Firebase key

Push notifications read the service-account JSON from the path in
`FIREBASE_SERVICE_ACCOUNT_KEY`. `docker-compose.prod.yml` mounts nothing for
it, so if that path is inside the checkout the container only sees the key
because `COPY . .` bakes it into the image — which is why `.dockerignore`
deliberately does **not** exclude it. Moving it out of the image is a manual,
ordered change (do not reorder; step 2 before step 1 stops every push):

1. On the server, move the key outside the checkout
   (`mkdir -p /root/p4td-secrets && mv /root/p4td/<key>.json /root/p4td-secrets/firebase.json && chmod 640 /root/p4td-secrets/firebase.json && chown root:1000 /root/p4td-secrets/firebase.json`).
2. Add to the `web` service's `volumes:` in `docker-compose.prod.yml`:
   `- /root/p4td-secrets/firebase.json:/run/secrets/firebase.json:ro`, and set
   `FIREBASE_SERVICE_ACCOUNT_KEY=/run/secrets/firebase.json` in `.env`.
3. Deploy, confirm a push arrives, and only then add the old filename to
   `.dockerignore`.

## Optional settings added with the review fixes

All read from the environment (`.env`); all safe to leave unset.

| Variable | Effect |
|---|---|
| `BACKUP_OFFBOX_CMD` | Command run after a successful backup to copy it off the server. Unset = local only. |
| `BACKUP_HEARTBEAT_URL` | Pinged after a fully successful backup (defaults to `$P4TD_CRON_HEARTBEAT_URL/backup`). |
| `BACKUP_RETENTION` | How many of each backup artefact to keep (default 7). |
| `STREET_MANAGER_HIGHWAY_AUTHORITIES` | Comma-separated authority names / SWA codes whose roadworks are stored. Unset = all. Enforced where rows are written, as well as by the SNS filter policy. |
| `SNS_MAX_MESSAGE_AGE_SECONDS` | How old a Street Manager message's signed timestamp may be (default 3600). Older ones are refused: every subscriber holds signed copies, so without this an old "road closed" could be replayed. |
| `P4TD_CRON_ALLOW_NO_PUSH` | `1` lets the reminder commands run with no Firebase key. |
| `DEMO_PASSWORD` | Password for `seed_demo_data` when `--password` is not given. There is no default. |

## Owner's to-do

Things the repository cannot do for itself. None of these has been done.

1. **Rotate the demo account's password.** A default for it was committed to
   this public repository (and is still in its history and in
   `my_app/SCREENSHOTS.md`), and the screenshot workflow's verbose log could
   carry it too. On the server:
   `docker compose -f docker-compose.prod.yml exec -T -e DEMO_PASSWORD='<new>' web python manage.py seed_demo_data --no-media`
   then update the `DEMO_PASSWORD` repository secret, and delete old **Store
   Screenshots** runs (their logs and `ios-drive-log` artifacts).
2. **Cap request size in the live Caddy.** Add to the p4td block of
   `/root/caddy/Caddyfile`: `request_body { max_size 250MB }`, then
   `docker exec caddy-caddy-1 caddy reload --config /etc/caddy/Caddyfile`.
3. **Send backups off the server.** Configure a remote (e.g. `rclone config`)
   and set `BACKUP_OFFBOX_CMD` in `/root/p4td/.env`. Then rehearse a restore.
4. **Point the heartbeat somewhere.** Set `P4TD_CRON_HEARTBEAT_URL` to a
   healthchecks.io-style base URL, with a check per suffix the commands ping
   (`vaccination-reminders`, `fleet-reminders`, `send_compliance_reminders`,
   `end-of-day-alerts`, `tomorrow-changes`, `monthly-invoices`,
   `invoice-reminders`, `xero-sync`, `prune-feed-media`, `backup`). Without it
   a failing job is only a line in `/var/log`.
5. **Turn on a firewall** (recommended; there is none, and the address of this
   server has been public in this repository's history):
   `ufw default deny incoming && ufw default allow outgoing && ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp && ufw enable`.
   Docker publishes ports around ufw, so keep binding the app to `172.17.0.1`
   as now; check the other apps on the box before enabling.
6. **Deploy as something less than root** (recommended). The GitHub deploy key
   is currently a root login. Restrict it to the one command it needs, in
   `/root/.ssh/authorized_keys`:
   `command="cd /root/p4td && ./deploy.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... github-actions-deploy`
   (the workflow's failure step also runs `tail .deploy-history`, which this
   would turn into a second deploy — drop that step or allow it through a
   wrapper that switches on `$SSH_ORIGINAL_COMMAND`). A dedicated non-root
   user in the `docker` group is the further step.
7. **Require approval for the `production` environment** (GitHub > Settings >
   Environments) if a human should confirm each deploy, and keep "Require
   approval for all outside collaborators" on for workflow runs from forks.
8. **Move the Firebase key out of the image** — see [Firebase key](#firebase-key).
9. Old images built before `private-media/` was added to `.dockerignore`
   contain copies of every vaccination certificate. The deploy now prunes this
   project's untagged images after a week; to clear them at once:
   `docker image prune -f --filter label=com.docker.compose.project=p4td`.

## One-time / periodic ops

Server-side setup that can't be done from the repo:

- **`CONTACT_INQUIRY_EMAIL`**: set it so contact-form enquiries reach a
  monitored inbox (falls back to `DEFAULT_FROM_EMAIL`).
- **Rollback** is manual: `deploy.sh` records the prior commit and image id in
  `.deploy-history` and prints the rollback command.
