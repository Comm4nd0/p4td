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

- **Dart SDK**: >=3.2.6
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

| Endpoint | Resource |
|---|---|
| `api/dogs/` | Dog profiles |
| `api/profile/` | User profiles |
| `api/feed/` | Activity feed / media |
| `api/comments/` | Feed comments |
| `api/date-change-requests/` | Schedule change requests |
| `api/boarding-requests/` | Boarding requests |
| `api/daily-assignments/` | Staff-dog daily assignments |
| `api/support-queries/` | Support tickets |
| `api/closure-days/` | Facility closures |
| `api/dog-notes/` | Behavioral/compatibility notes |
| `api/staff-availability/` | Staff coverage |
| `api/day-off-requests/` | Staff day-off requests |
| `api/device-tokens/` | Push notification tokens |
| `api/contact-inquiries/` | Website contact form |
| `api/vehicles/` | Fleet vehicles (MOT/service tracking) |
| `api/vehicle-defects/` | Vehicle defect reports with photos |

Additional non-router endpoints: password reset/change, account deletion.

## Architecture & Key Patterns

### Backend

- **ViewSets + DefaultRouter** for REST endpoints
- **Custom permissions** via `UserProfile` flags: `can_manage_requests`, `can_assign_dogs`, `can_reply_queries`, `can_view_all_dogs`, `can_upload_media`
- **Token + Session auth** via djoser
- **Signals** auto-create `UserProfile` on `User` creation and notify staff on contact inquiries
- **Image processing** with Pillow (EXIF rotation, compression, thumbnails)
- **Push notifications** via Firebase Admin SDK

### Mobile (Flutter)

- **Services-based architecture**: `DataService`, `AuthService`, `NotificationService`, `CacheService`
- **StatefulWidget** patterns with service-layer data management
- **Hive** for local offline caching
- **Firebase Messaging** + local notifications
- **Phosphor Icons** (Duotone variant), **Nunito** font via google_fonts

## Naming Conventions

- **Python**: `snake_case` for functions/variables, `CamelCase` for classes
- **Dart**: `camelCase` for variables/functions, `PascalCase` for classes
- **URLs**: `kebab-case` (e.g. `date-change-requests`)
- **Django models**: singular `CamelCase` (e.g. `BoardingRequest`, `DogNote`)

## Deployment

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
- Firebase and AWS S3 credentials for notifications and media storage

## Management Commands

| Command | Purpose |
|---|---|
| `python manage.py prune_feed_media` | Delete old feed media (GroupMedia) and optionally remove orphaned files |
| `python manage.py send_fleet_reminders` | Push MOT/service due reminders to staff with `can_manage_vehicles` (daily 8:05am cron) |

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
- **Production schedule**: Runs automatically every Sunday at 3am via host cron (set up by `scripts/deploy-to-hetzner.sh`)
- **Log file**: `/var/log/p4td-prune.log` (on production server)
- **Tests**: `python manage.py test api.tests.PruneFeedMediaTests`

## Important Notes

- The `app/` directory is a **legacy Android app** — the active mobile client is `my_app/` (Flutter)
- No backend linter is configured — follow standard Django/PEP 8 conventions
- Media files and `.env` are gitignored
- Line endings: LF enforced for `.sh` files via `.gitattributes`
- The backend has no automated CI — only the Flutter/Android build has a GitHub Actions workflow
