# p4td — Paws 4 Thought Dogs

A dog daycare management platform with three components:

- **Django REST API backend** (`api/`, `p4td_backend/`) — scheduling, boarding,
  staff management, notifications.
- **Flutter mobile app** (`my_app/`) — cross-platform client for owners and staff.
- **Django website** (`website/`) — the public marketing site (templates, forms).

The business operates in Berkshire & Buckinghamshire, UK.

## Quick start

1. Copy `.env.example` to `.env` and fill required values (e.g. `DJANGO_SECRET_KEY`).
2. Backend — create a virtualenv and install dependencies:

   ```bash
   python -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   python manage.py migrate
   python manage.py runserver
   ```

   The website is served by the same Django project.

3. Mobile — follow the Flutter setup in [`my_app/README.md`](my_app/README.md)
   (ensure `local.properties` and Firebase config files are not committed).

### Docker (local dev)

`docker-compose.yml` brings up PostgreSQL + Django for local development:

```bash
docker compose up
```

(`docker-compose.prod.yml` is the production stack on Hetzner.)

## Running tests

```bash
# Backend
python manage.py test api.tests

# Mobile
cd my_app && flutter test
```

## More docs

- [`CLAUDE.md`](CLAUDE.md) — full project guide (architecture, endpoints,
  deployment, conventions, management commands).
- [`FUNCTIONALITY_GUIDE.md`](FUNCTIONALITY_GUIDE.md) — owner & staff feature overview.
- [`BACKEND_DAYCARE_INTEGRATION.md`](BACKEND_DAYCARE_INTEGRATION.md) and
  [`DAYCARE_SCHEDULE_FEATURE.md`](DAYCARE_SCHEDULE_FEATURE.md) — daycare schedule feature.
