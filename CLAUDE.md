# CLAUDE.md — AI Assistant Guide for p4td

## Project Overview

**p4td (Paws 4 Thought Dogs)** is a dog daycare management platform with three components:
- **Django REST API Backend** — scheduling, boarding, staff management, notifications
- **Flutter Mobile App** (`my_app/`) — cross-platform client for owners and staff
- **Django Website** (`website/`) — public marketing site with templates

The business operates in Berkshire & Buckinghamshire, UK.

## Repository Structure

```
p4td/
├── api/                    # Django REST API app (models, views, serializers, tests)
├── p4td_backend/           # Django project settings, URLs, WSGI
├── website/                # Public website (templates, models, forms)
├── my_app/                 # Flutter mobile app
│   ├── lib/
│   │   ├── screens/        # UI screens
│   │   ├── models/         # Dart data models
│   │   ├── services/       # API, auth, notifications, cache services
│   │   ├── widgets/        # Reusable components
│   │   └── constants/      # Colors, strings
│   ├── android/            # Android platform config
│   ├── ios/                # iOS platform config
│   └── pubspec.yaml        # Dart dependencies
├── templates/              # Shared Django templates
├── scripts/                # Deployment scripts (Hetzner)
├── docker-compose.yml      # Local dev (PostgreSQL + Django)
├── docker-compose.prod.yml # Production (Hetzner CX22)
├── Dockerfile              # Multi-stage production build (Python 3.11)
├── Caddyfile               # Reverse proxy (auto HTTPS, media serving)
├── app/                    # Legacy Android app (not actively maintained)
└── .github/workflows/      # CI: Android Play Store deployment
```

## Development Setup

### Backend (Django)

```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # Fill in DJANGO_SECRET_KEY and other values
python manage.py migrate
python manage.py runserver
```

- **Dev DB**: SQLite (default)
- **Prod DB**: PostgreSQL 15
- **Python version**: 3.11
- **Django version**: 5.2.10

### Mobile (Flutter)

```bash
cd my_app
flutter pub get
flutter run
```

- **Dart SDK**: >=3.3.0 <4.0.0
- **Flutter channel**: stable

## Running Tests

### Backend

```bash
python manage.py test api.tests
# Run a specific test class:
python manage.py test api.tests.DateChangeRequestStatusTests
```

Tests are in `api/tests.py` — integration tests using DRF's `APIClient` covering all major features (date changes, dogs CRUD, assignments, boarding, support queries, closures, notes, staff availability, feed).

### Mobile

```bash
cd my_app
flutter test
flutter analyze
```

Linting uses `flutter_lints` (config in `my_app/analysis_options.yaml`).

## API Endpoints

All API routes are registered via DRF `DefaultRouter` in `api/urls.py`, mounted at `/api/`:

> **Source of truth:** `api/urls.py` defines the full set of router registrations and non-router routes. If this table and `api/urls.py` disagree, the code wins.

| Endpoint | Resource |
|---|---|
| `api/profile/` | User profiles |
| `api/dogs/` | Dog profiles |
| `api/photos/` | Dog photos/videos |
| `api/date-change-requests/` | Schedule change requests |
| `api/feed/` | Activity feed / group media |
| `api/comments/` | Feed comments |
| `api/boarding-requests/` | Boarding requests |
| `api/device-tokens/` | Push notification tokens |
| `api/daily-assignments/` | Staff-dog daily assignments |
| `api/support-queries/` | Support tickets |
| `api/closure-days/` | Facility closures |
| `api/dog-notes/` | Behavioral/compatibility notes |
| `api/staff-availability/` | Staff coverage |
| `api/day-off-requests/` | Staff day-off requests |
| `api/contact-inquiries/` | Website contact form |
| `api/dog-profile-changes/` | Owner-requested dog profile change requests |
| `api/vaccinations/` | Dog vaccination records |
| `api/waitlist/` | Daycare waitlist entries |
| `api/vehicles/` | Fleet vehicles (MOT/service tracking) |
| `api/vehicle-defects/` | Vehicle defect reports with photos |
| `api/facility-defects/` | Facility defect reports |
| `api/intake-requests/` | Booking forms (owner dog-intake requests; staff approve to create dogs) |
| `api/invoices/` | Monthly customer invoices (owners view/pay their own; staff with `can_manage_payments` generate/send/record payments/sync Xero) |

Additional non-router endpoints:
- `api/daycare-settings/` — facility-wide daycare settings
- `api/password/reset/request/`, `api/password/reset/verify/`, `api/password/reset/confirm/` — password reset OTP flow
- `api/password/change/` — change password while logged in
- `api/account/delete/` — account deletion
- `api/postcode/lookup/` — UK postcode address lookup (getAddress.io)
- `api/xero/status/`, `api/xero/connect/`, `api/xero/callback/`, `api/xero/disconnect/` — Xero OAuth2 connection management (superuser-only; the callback is a browser redirect authenticated by its one-shot state token)

## Architecture & Key Patterns

### Backend

- **ViewSets + DefaultRouter** for REST endpoints
- **Custom permissions** via `UserProfile` flags: `can_assign_dogs`, `can_add_feed_media`, `can_manage_requests`, `can_reply_queries`, `can_approve_timeoff`, `can_view_inquiries`, `can_manage_vehicles`, `can_manage_payments`, `can_manage_boarding`
- **Token + Session auth** via djoser
- **Signals** auto-create `UserProfile` on `User` creation and notify staff on contact inquiries
- **Image processing** with Pillow (EXIF rotation, compression, thumbnails)
- **Push notifications** via Firebase Admin SDK

### Mobile (Flutter)

- **Services-based architecture**: `DataService`, `AuthService`, `NotificationService`, `CacheService`
- **StatefulWidget** patterns with service-layer data management
- **Hive** for local offline caching
- **Firebase Messaging** + local notifications
- **Picons** icon set (`picons` package), **Nunito** font via google_fonts

## Naming Conventions

- **Python**: `snake_case` for functions/variables, `CamelCase` for classes
- **Dart**: `camelCase` for variables/functions, `PascalCase` for classes
- **URLs**: `kebab-case` (e.g. `date-change-requests`)
- **Django models**: singular `CamelCase` (e.g. `BoardingRequest`, `DogNote`)

## Deployment

> **Read [`DEPLOYMENT.md`](DEPLOYMENT.md) before changing anything that serves the app.**
> The prod box is multi-tenant: a *separate* Caddy container fronts several apps and
> reaches p4td via the host port `172.17.0.1:8000` (not the Docker network), and media
> is a host bind-mount Caddy serves directly. The committed `Caddyfile` is reference
> only; the live one is `/root/caddy/Caddyfile` on the server.

- **Infrastructure**: Hetzner CX22, Docker Compose, Caddy reverse proxy
- **Backend deploy**: `scripts/deploy-to-hetzner.sh` (manual SSH-based)
- **Mobile deploy**: GitHub Actions workflow (`.github/workflows/deploy-android-alpha.yml`) — builds AAB and uploads to Google Play alpha track on push to `main` with `my_app/` changes
- **Production server**: Gunicorn (2 workers, 2 threads, 120s timeout)

### Mobile version bumps (required)

**Every commit that changes anything under `my_app/` must bump the version in `my_app/pubspec.yaml`.** The Play Store build fails if the build code (the number after the `+`) is not greater than the previously uploaded one.

- Format: `version: <major>.<minor>.<patch>+<buildNumber>`
- Default: bump patch and build number by 1 (e.g. `1.7.8+271` → `1.7.9+272`).
- Bump major/minor only when the change warrants it.
- Make the bump part of the same commit as the feature change (or as an immediate follow-up commit before pushing).

## Environment Variables

See `.env.example` for required variables. Key ones:
- `DJANGO_SECRET_KEY` — required
- `DOMAIN` — production domain
- `DB_NAME`, `DB_USER`, `DB_PASSWORD` — PostgreSQL credentials (prod)
- `CORS_ALLOWED_ORIGINS`, `CSRF_TRUSTED_ORIGINS` — security origins
- `POSTCODE_LOOKUP_API_KEY` — getAddress.io API key powering the `/api/postcode/lookup/` endpoint (UK postcode → address). Optional; leave blank to disable the lookup feature. Distinct from the keyless postcodes.io geocoding used by `geocode_dogs`.
- `XERO_CLIENT_ID`, `XERO_CLIENT_SECRET`, `XERO_REDIRECT_URI` — Xero OAuth2 app credentials for monthly invoicing (create a "Web app" at developer.xero.com whose redirect URI exactly matches `XERO_REDIRECT_URI`). Optional; leave blank to disable — invoicing still works locally, just without the online payment link. A superuser completes the one-time consent via `POST /api/xero/connect/`.
- `XERO_PAYMENT_ACCOUNT_CODE` — Xero account code that staff-recorded manual payments are booked against in Xero. Blank = manual payments stay app-only (Xero will keep showing the invoice unpaid, and if staff then also key the payment into Xero the sync imports it as a duplicate — keep this configured).
- Firebase and AWS S3 credentials for notifications and media storage

## Management Commands

All commands live in `api/management/commands/` (ignore `__init__.py`).

| Command | Purpose | Cron |
|---|---|---|
| `python manage.py import_dogs` | Bulk import dogs from a text file (one name per line) or CSV (`owner_username,dog_name`). `--owner`, `--dry-run` | — |
| `python manage.py seed_demo_data` | Seed/refresh the demo owner account (with a demo dog, gallery, and feed) used for App Store / Play Store screenshots. Idempotent; `--no-media` | — |
| `python manage.py geocode_dogs` | Geocode dog pickup addresses (postcodes.io, free, no API key) and cache lat/lng on each Dog for the staff pickup map. Idempotent; `--dry-run`, `--force`, `--limit`, `--sleep` | — |
| `python manage.py send_vaccination_reminders` | Send push reminders to owners for vaccinations that are expiring or expired | Daily 8:00am |
| `python manage.py send_fleet_reminders` | Push MOT/service due reminders to staff with `can_manage_vehicles` | Daily 8:05am |
| `python manage.py prune_feed_media` | Delete old feed media (GroupMedia) and optionally remove orphaned files | Weekly, Sun 3am (with `--include-orphans`) |
| `python manage.py prune_device_tokens` | Delete stale push-notification device tokens not refreshed in N days (default 90); live devices re-register on launch. `--days`, `--dry-run` | — |
| `python manage.py generate_monthly_invoices` | Generate draft invoices for the previous month from attendance; notifies staff with `can_manage_payments` to review/send. Idempotent; `--year`, `--month` | Monthly, 1st 6:00am |
| `python manage.py sync_xero_invoices` | Pull payment status for open invoices back from Xero (no-op when Xero not connected) | Every 30 min |
| `python manage.py send_invoice_reminders` | Push overdue payment reminders to invoice owners (once per invoice) | Daily 9:00am |

### Feed Media Pruning

The `prune_feed_media` command prevents the server from filling up by removing old feed posts (GroupMedia only — dog photos, profile pictures, and website content are not affected).

```bash
# Preview what would be deleted (no changes made)
python manage.py prune_feed_media --dry-run

# Delete feed media older than 90 days (default)
python manage.py prune_feed_media

# Custom retention period (e.g. 180 days)
python manage.py prune_feed_media --days 180

# Also remove orphaned files in group_media/ with no DB record
python manage.py prune_feed_media --include-orphans
```

- **Default retention**: 90 days
- **Production schedule**: Runs automatically every Sunday at 3am via host cron (set up by `scripts/deploy-to-hetzner.sh`). The production cron runs **with `--include-orphans`**, so orphaned files are also removed.
- **Log file**: `/var/log/p4td-prune.log` (on production server)
- **Tests**: `python manage.py test api.tests.PruneFeedMediaTests`

## Important Notes

- The `app/` directory is a **legacy Android app** — the active mobile client is `my_app/` (Flutter)
- No backend linter is configured — follow standard Django/PEP 8 conventions
- Media files and `.env` are gitignored
- Line endings: LF enforced for `.sh` files via `.gitattributes`
- The backend has no automated CI — only the Flutter/Android build has a GitHub Actions workflow
