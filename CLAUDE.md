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
└── .github/workflows/      # CI: backend tests, Flutter tests, Play Store deployment
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
| `api/incidents/` | **Staff-only** incident log — scuffles, bites, injuries, escapes. Tied to the dogs involved (per-dog role/injuries/owner-told), with photos *and* video, follow-up comments and a status. Owners get 403 on every route, including `?dog=<id>` for their own dog. |

Additional non-router endpoints:
- `api/daycare-settings/` — facility-wide daycare settings
- `api/billing-settings/` — standard daycare/boarding prices (payment managers; backed by the website ServicePricing singleton)
- `api/customer-rates/` — per-customer billing rate overrides / discounts and billing mode (payment managers). `billing_mode` gates the invoicing transition: `MANUAL` customers (the default) are still invoiced by hand in Xero and skipped by monthly generation; `APP` customers get auto-generated invoices. Explicit single-customer generation bypasses the flag.
- `api/password/reset/request/`, `api/password/reset/verify/`, `api/password/reset/confirm/` — password reset OTP flow
- `api/password/change/` — change password while logged in
- `api/account/delete/` — account deletion
- `api/postcode/lookup/` — UK postcode address lookup (getAddress.io)
- `api/roadworks/` — roadworks in force on a date, each already matched to the staff
  routes and dogs it disrupts (staff-only; owners get 403). One call feeds all three
  surfaces: the dashboard's red ring, the banner on a staff member's dog list, and the
  pickup map's cone pins.
- `api/roadworks/street-manager-webhook/` — **public** endpoint receiving DfT Street
  Manager open data pushed over AWS SNS. Unauthenticated by necessity (AWS holds no
  credential of ours); trust comes entirely from the SNS signature check in `api/sns.py`.
  Returns 503 until `STREET_MANAGER_TOPIC_ARNS` is set, so it is inert by default.
- `api/xero/status/`, `api/xero/connect/`, `api/xero/callback/`, `api/xero/disconnect/` — Xero OAuth2 connection management (superuser-only; the callback is a browser redirect authenticated by its one-shot state token)
- `api/xero/contact-matches/`, `api/xero/pin-contact/`, `api/xero/contacts/` — Xero contact reconciliation (payment managers): match app customers to their existing Xero contacts, pin the right ContactID, and search contacts. Pinned/matched ids are stored on the profile (and on ownerless dogs) so invoice pushes reuse the existing contact instead of creating duplicates.

## Architecture & Key Patterns

### Backend

- **ViewSets + DefaultRouter** for REST endpoints
- **Custom permissions** via `UserProfile` flags: `can_assign_dogs`, `can_add_feed_media`, `can_manage_requests`, `can_reply_queries`, `can_manage_staff`, `can_view_inquiries`, `can_manage_vehicles`, `can_manage_payments`, `can_manage_boarding`
- **Token + Session auth** via djoser
- **Signals** auto-create `UserProfile` on `User` creation and notify staff on contact inquiries
- **Boarding dogs attend daycare**: approving a stay books its dogs into daycare
  for every weekday it covers — arrival and departure days included — under the
  business's own `P4TD` pseudo-staff account (`api/scheduling.py`:
  `sync_boarding_daycare_assignments`). Cancelling/denying/moving the stay
  releases those rows again; only rows flagged `DailyDogAssignment.from_boarding`
  are ever touched. Billing-neutral by construction —
  `billing.attendance_for_month` already skips days inside an approved stay, so
  the boarding nights are the only charge.
  A weekday arrival is the exception: the dog is still at home that morning and
  needs collecting, so that day is created `UNASSIGNED` with no staff member and
  surfaces in `unassigned_dogs` for a driver to claim. It goes to `P4TD` as
  usual when the owner normally brings the dog in themselves
  (`Dog.owner_brings_default`, or the per-date `owner_brings` override), when
  the stay starts at a weekend (by its first weekday the dog is already with the
  carer), or when it runs straight on from another approved stay.
- **Image processing** with Pillow (EXIF rotation, compression, thumbnails)
- **Push notifications** via Firebase Admin SDK

### Mobile (Flutter)

- **Services-based architecture**: `DataService`, `AuthService`, `NotificationService`, `CacheService`, `BiometricService`
- **App lock**: opt-in biometric gate (`BiometricService` + `AppLockScreen`) over the
  already-persisted session. Rendered as an overlay in `MaterialApp.builder` so it covers
  every route and leaves the Navigator mounted underneath. Android needs
  `FlutterFragmentActivity` for `local_auth`'s BiometricPrompt.
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
- **Backend deploy**: automatic — a successful `Backend CI` run on `main` triggers
  `.github/workflows/deploy-backend.yml`, which SSHes to the server, runs `./deploy.sh`,
  and verifies `/healthz/` through Caddy. Manual entry points remain:
  `scripts/deploy-to-hetzner.sh` (from a laptop) or `./deploy.sh` (on the server). All
  pull `main` only, with `--ff-only`, and gate on `/healthz/` before reporting success.
  Because the deploy is gated on `Backend CI`, anything that changes production
  behaviour must appear in that workflow's path filters or it will never ship.
- **Mobile deploy (Android)**: GitHub Actions workflow (`.github/workflows/deploy-android-alpha.yml`) — builds AAB and uploads to Google Play alpha track on push to `main` with `my_app/` changes
- **Mobile deploy (iOS)**: Xcode Cloud archives and uploads to TestFlight on push
  to `main` (bootstrapped by `my_app/ios/ci_scripts/ci_post_clone.sh`). Shipping to
  the App Store is a `v*` tag, which runs `.github/workflows/deploy-ios-release.yml`
  — see [Releasing iOS](#releasing-ios) below.
- **Production server**: Gunicorn (2 workers, 2 threads, 120s timeout)

### Mobile version bumps (required)

**Every commit that changes anything under `my_app/` must bump the version in `my_app/pubspec.yaml`.** The Play Store build fails if the build code (the number after the `+`) is not greater than the previously uploaded one, and so does App Store Connect.

- Format: `version: <major>.<minor>.<patch>+<buildNumber>`
- Default: bump patch and build number by 1 (e.g. `1.7.8+271` → `1.7.9+272`).
- Bump major/minor only when the change warrants it.
- Make the bump part of the same commit as the feature change (or as an immediate follow-up commit before pushing).

### Releasing iOS

`pubspec.yaml` is the source of the iOS **marketing version** (the Xcode project
takes `MARKETING_VERSION` from `$(FLUTTER_BUILD_NAME)` via
`ios/Flutter/Generated.xcconfig`, written by `flutter pub get`). It is *not* the
source of the iOS build number: Xcode Cloud stamps its own counter into
`CFBundleVersion` when it distributes, so pubspec's `+<buildNumber>` governs
Android only. That counter is shared across the product's Xcode Cloud workflows,
so it stays unique — don't try to "fix" it to match pubspec.

The release workflow therefore resolves the build by **version train**, which is
keyed on the marketing version. That makes the required version bump
load-bearing: skip it and a release shares a train with the previous one and can
attach the wrong binary.

To ship, tag a commit that is already on `main` and whose pubspec carries the
version being released:

```bash
git tag v1.9.26 && git push origin v1.9.26
```

The workflow verifies the tag matches pubspec and is an ancestor of `main`,
pushes the listing from `my_app/fastlane/metadata/`, waits for a build of that
version to finish processing, attaches the newest one, and submits for review. It
never builds or uploads a binary itself. Full detail — including the dry-run mode
and what still needs the web UI — is in `my_app/STORE_METADATA.md`.

## Environment Variables

See `.env.example` for required variables. Key ones:
- `DJANGO_SECRET_KEY` — required
- `DJANGO_ALLOWED_HOSTS` — comma-separated production hostnames
- `RDS_DB_NAME`, `RDS_USERNAME`, `RDS_PASSWORD`, `RDS_HOSTNAME`, `RDS_PORT` — PostgreSQL
  credentials (prod). Note the `RDS_` prefix: `settings.py` switches to PostgreSQL only when
  `RDS_HOSTNAME` (or `DATABASE_URL`) is set, and silently falls back to SQLite otherwise.
- `DJANGO_EMAIL_BACKEND` — must be set to `django.core.mail.backends.smtp.EmailBackend` in
  production (with `EMAIL_HOST_USER` / `EMAIL_HOST_PASSWORD`). The default is the *console*
  backend, which silently discards password-reset codes and contact enquiries.
- `CONTACT_INQUIRY_EMAIL` — where website/app enquiries are sent (defaults to `DEFAULT_FROM_EMAIL`)
- `SENTRY_DSN` — optional; enables error reporting. Also `SENTRY_TRACES_SAMPLE_RATE`, `SENTRY_ENVIRONMENT`
- `P4TD_CRON_HEARTBEAT_URL` — optional dead-man's-switch pinged by the scheduled commands
- `CORS_ALLOWED_ORIGINS`, `CSRF_TRUSTED_ORIGINS` — security origins
- `POSTCODE_LOOKUP_API_KEY` — getAddress.io API key powering the `/api/postcode/lookup/` endpoint (UK postcode → address). Optional; leave blank to disable the lookup feature. Distinct from the keyless postcodes.io geocoding used by `geocode_dogs`.
- `XERO_CLIENT_ID`, `XERO_CLIENT_SECRET`, `XERO_REDIRECT_URI` — Xero OAuth2 app credentials for monthly invoicing (create a "Web app" at developer.xero.com whose redirect URI exactly matches `XERO_REDIRECT_URI`). Optional; leave blank to disable — invoicing still works locally, just without the online payment link. A superuser completes the one-time consent via `POST /api/xero/connect/`.
- `XERO_PAYMENT_ACCOUNT_CODE` — Xero account code that staff-recorded manual payments are booked against in Xero. Blank = manual payments stay app-only (Xero will keep showing the invoice unpaid, and if staff then also key the payment into Xero the sync imports it as a duplicate — keep this configured).
- `XERO_EMAIL_INVOICES` — when true (default), sending an invoice also asks Xero to email it to the customer with the org's branding theme (the same email customers got when invoices were raised by hand in Xero). Set false for app push notifications only.
- `STREET_MANAGER_TOPIC_ARNS` — comma-separated AWS SNS topic ARNs for the DfT Street
  Manager roadworks feed. Blank = the feature is dormant (webhook 503s, nothing is ever
  flagged). Going live needs the organisation registered at
  https://www.manage-roadworks.service.gov.uk/open-data-onboarding with this server's
  webhook URL — Street Manager has no polling API for open-data consumers, it pushes.
  Apply an SNS subscription filter policy on `highway_authority`: the topic carries the
  whole country's street works.
- `ROADWORK_MATCH_RADIUS_M` — metres from a dog's cached pickup coordinates within which
  a roadwork flags that staff member's route (default 400).
- Firebase credentials for push notifications. Media is stored on local disk
  (`FileSystemStorage`) and served by Caddy — there is no S3 integration.

## Management Commands

All commands live in `api/management/commands/` (ignore `__init__.py`).

| Command | Purpose | Cron |
|---|---|---|
| `python manage.py import_dogs` | Bulk import dogs from a text file (one name per line) or CSV (`owner_username,dog_name`). `--owner`, `--dry-run` | — |
| `python manage.py seed_demo_data` | Seed/refresh the demo owner account (with a demo dog, gallery, and feed) used for App Store / Play Store screenshots. Idempotent; `--no-media` | — |
| `python manage.py geocode_dogs` | Geocode dog pickup addresses (postcodes.io, free, no API key) and cache lat/lng on each Dog for the staff pickup map. Idempotent; `--dry-run`, `--force`, `--limit`, `--sleep` | — |
| `python manage.py send_vaccination_reminders` | Send push reminders to owners for vaccinations that are expiring or expired | Daily 8:00am |
| `python manage.py send_fleet_reminders` | Push MOT/service due reminders to staff with `can_manage_vehicles` | Daily 8:05am |
| `python manage.py prune_feed_media` | Delete old feed media (GroupMedia) and optionally remove orphaned files. Never touches dog gallery photos — see [Feed Media Pruning](#feed-media-pruning) | Weekly, Sun 3am (with `--include-orphans`) |
| `python manage.py prune_device_tokens` | Delete stale push-notification device tokens not refreshed in N days (default 90); live devices re-register on launch. `--days`, `--dry-run` | — |
| `python manage.py prune_auth_tokens` | Delete DRF auth tokens older than N days so an abandoned device's token can't be reused indefinitely (tokens never expire on their own). `--days`, `--dry-run` | — |
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

# Also remove orphaned files in group_media/ and dog_photos/ with no DB record
python manage.py prune_feed_media --include-orphans
```

- **Default retention**: 90 days
- **Production schedule**: Runs automatically every Sunday at 3am via host cron (set up by `scripts/deploy-to-hetzner.sh`). The production cron runs **with `--include-orphans`**, so orphaned files are also removed.
- **Log file**: `/var/log/p4td-prune.log` (on production server)
- **Tests**: `python manage.py test api.tests.PruneFeedMediaTests api.tests.DogPhotoRetentionTests`

**Dog gallery photos are never pruned by age, and must stay that way.** Staff
photograph vaccination cards and other medical paperwork into a dog's gallery,
so a `Photo` row is a record, not a snapshot: it goes only when someone deletes
that photo or the dog itself (`DogViewSet.destroy` clears the files with it).
Do not add `Photo` to the retention pass. `--include-orphans` does sweep
`dog_photos/`, but only as a backstop for files whose row is already gone — and
before it removes anything, a file must be absent from the reference snapshot,
be older than `--orphan-grace-hours` (default 24, since Django writes an upload
to disk before committing its row), *and* still be unreferenced on a second
database check taken after the directory walk.

## Important Notes

- The `app/` directory is a **legacy Android app** — the active mobile client is `my_app/` (Flutter)
- No backend linter is configured — follow standard Django/PEP 8 conventions
- Media files and `.env` are gitignored
- Line endings: LF enforced for `.sh` files via `.gitattributes`
- CI: `backend-ci.yml` (Django checks + full suite against PostgreSQL 15, plus a dependency
  audit and a Docker build), `flutter-ci.yml` (analyze + test + pubspec version-bump check),
  `deploy-android-alpha.yml` (Play Store alpha upload), `store-screenshots.yml` (manual),
  `app-store-metadata.yml` (manual — pushes the App Store listing text from
  `my_app/fastlane/metadata/`; see `my_app/STORE_METADATA.md`),
  `deploy-ios-release.yml` (on a `v*` tag — pushes the listing, attaches the
  Xcode Cloud build for that commit, and submits it for App Review),
  `deploy-backend.yml` (production deploy, triggered by a green `Backend CI` on `main`).
