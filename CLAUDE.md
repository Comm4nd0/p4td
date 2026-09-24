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
- **Django version**: 5.2.17

### Mobile (Flutter)

```bash
cd my_app
flutter pub get
flutter run
```

- **Dart SDK**: >=3.3.0 <4.0.0
- **Flutter SDK**: pinned in `my_app/.flutter-version` — see [Flutter version pin](#flutter-version-pin)

### Flutter version pin

**`my_app/.flutter-version` is the only place the Flutter version is written.**
Every build surface reads it: all four `subosito/flutter-action` steps across
`flutter-ci.yml`, `deploy-android-alpha.yml` and `store-screenshots.yml`, and
`my_app/ios/ci_scripts/ci_post_clone.sh` for Xcode Cloud. To upgrade, change
that one line — and nothing else.

This is not a style preference; the split cost two broken releases. The
workflows used to install `channel: stable`, which silently followed Flutter
forward: the Android release build broke the day stable became 3.47 and the
pinned Gradle was suddenly too old, while `flutter analyze` and every test in
the same job passed. Xcode Cloud had the opposite failure — a hardcoded
version nobody remembered to touch, leaving iOS building on 3.41.2 six minor
versions behind everything else.

Xcode Cloud additionally pins *how* plugins are delivered. `ci_post_clone.sh`
runs `flutter config --no-enable-swift-package-manager` before `flutter pub
get`, because Xcode Cloud never runs `flutter build ios` — it calls xcodebuild
against `Runner.xcworkspace` directly, and only this script prepares the pods.
A plugin vended through Swift Package Manager would therefore be imported by
`GeneratedPluginRegistrant.m` and built by nothing, which is exactly the
`Module 'camera_avfoundation' not found` failure that appeared when iOS moved
from 3.41.2 to 3.47.0. The script then cross-checks every module the
registrant imports against `Podfile.lock` and fails with the plugin's name,
rather than letting it surface as an opaque module error in the Xcode log.

`scripts/check-flutter-pin.sh` enforces it, and runs as the `flutter-pin` job
in Flutter CI. It fails the build if the pin is missing or isn't an exact
version, if any workflow reintroduces a channel or hardcodes a version, if a
`flutter-action` step installs without naming the pin, or if `ci_post_clone.sh`
stops reading the file. `flutter-ci.yml` therefore triggers on
`.github/workflows/*.yml` as well as `my_app/**`, so the guard sees a workflow
edit that the app-only filter would have missed. Both CI and Xcode Cloud also
assert after install that the SDK they actually got matches the pin — the file
states an intent, those checks prove it was honoured.

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
| `api/dogs/` | Dog profiles. `general_notes` and `van_placement` are staff-written and are stripped from every non-staff read (`DogSerializer.STAFF_ONLY_READ_FIELDS`); owners may propose changes only to `OWNER_EDITABLE_DOG_FIELDS`, which go through `api/dog-profile-changes/`. **Pickup instructions are per dog, not per person:** `access_instructions` (keys, gates, where the dog waits) is owner-editable like the address, is what the booking form's `pickup_instructions` becomes on approval, and is what `daily-assignments/` serves as `pickup_instructions` — the profile has no such field (migration 0091 moved it onto the dogs), so two dogs at one address can differ. **Contact numbers are client-required, staff-warned:** `contact_number` and `emergency_contact_number` (`CLIENT_REQUIRED_DOG_FIELDS` in `api/views.py`) must be given on the booking form and can never be blanked by an owner edit, while staff may leave them empty — the app asks a staff member once (`my_app/lib/widgets/dog_contact_rules.dart`) and the API never refuses. Put the next field that clients must supply but staff may skip under the same constant and helper. |
| `api/photos/` | Dog photos/videos. Owners view and upload to their own dogs' galleries; **deleting a photo is staff-only** — the gallery holds medical paperwork staff have photographed |
| `api/date-change-requests/` | Schedule change requests. Every row carries `dog_profile_image`; for staff, a PENDING `ADD_DAY`/`CHANGE` row also carries `new_date_summary` — dogs already booked on `new_date` (with capacity) and the staff due to work it (`scheduling.day_booking_summary`, which never counts the `P4TD` house account) — because that is what decides whether the extra day is approved. Owners always get `null` there |
| `api/feed/` | Activity feed / group media. Shared by every client, so it opens only once an account owns or co-owns a dog (i.e. after staff approve the booking form) — sign-up is self-service and a stranger must not be able to browse every dog's photos. Accounts with no dog get an empty page, not a 403, so the app's normal empty state covers it; the detail/react/comment routes inherit the gate through `get_object()`. `today_stats/` is staff-only. |
| `api/comments/` | Feed comments |
| `api/boarding-requests/` | Boarding requests |
| `api/device-tokens/` | Push notification tokens |
| `api/daily-assignments/` | Staff-dog daily assignments. `<id>/reassign/` moves one dog; `bulk_reassign/` (`assignment_ids`, `staff_member_id`, `scope`) moves several to one staff member in one transaction with the same `just_this_day`/`from_now_on` semantics — it backs the dashboard's **Reassign Dogs** quick action, next to Add Dog to Day. Rows already with the target are reported under `skipped`, not moved. `owner_handovers/` (GET `?date=`, POST `date`/`leg`/`staff_member_id`) is the dashboard's **Dropped off by owner / Collected by owner** pair: the day's dogs whose owner brings or collects them (`effective_owner_brings`/`effective_owner_collects`, boarding-aware, REMOVED excluded) and the staff member on each leg (`OwnerHandoverDuty`, one row per date and leg). Neither leg is on a driver's route, so the cards stay red until someone is named; any staff member can set it, like `assign_to_me`. `compatibility_conflicts/` rows carry `acknowledged_by_name`/`acknowledged_at`, set by `acknowledge_conflict/` (POST `date`, `dog_a`, `dog_b`; `ConflictAcknowledgement`, one per day and pair, first acknowledger kept) — "someone on the team has seen this", shared by everyone, logged under `SCHEDULE`; the banner still shows the pair, only the dashboard spotlight stops |
| `api/support-queries/` | Support tickets. Creating one pushes staff with `can_reply_queries`; `add_message/` pushes the other side of the thread (category `messages`). The detail carries `owner_dogs` (id, name, photo) for staff — the conversation header names the client, links to their details and opens each dog — and `null` for owners. **The staff badge (`unresolved_count/`) counts threads awaiting a reply, not unseen ones:** `staff_has_unread` is set by an owner message and cleared only by a staff reply or a resolve — staff `mark_read/` is a no-op, so a thread opened and closed stays on the count until someone answers it |
| `api/closure-days/` | Facility closures |
| `api/dog-notes/` | Behavioral/compatibility notes |
| `api/dog-change-logs/` | **Staff-only activity log** — who did what, and when (`DogChangeLog`; the name is historical, it began as a dog's change trail and the endpoint stays so older app versions keep working). Every staff-facing write lands here under a `category`: `DOG` (field diffs over `dog_changes.TRACKED_FIELDS` written by the `Dog` save/delete signals, plus explicit `log_change` calls for vaccinations, certificates, gallery photos, notes and co-owners), `COMMS` (Contact Staff messages/replies/resolves, booking-form submissions and decisions, website enquiries arriving and being marked read/replied/deleted, traffic alerts), `CLIENTS`, `BOOKINGS` (date-change and boarding requests and decisions), `SCHEDULE` (assign/reassign/unassign/remove, transport overrides, swaps, auto-assign, closures — pickup/drop-off progress is deliberately not logged), `FLEET`, `INCIDENT`, `DEFECT`, `STAFF` (HR records, pay, meetings, appraisals, sickness, training, availability, day-off requests, permission changes), `COMPLIANCE`, `BILLING` (invoices, payments, prices, customer rates) and `SETTINGS`. Non-dog writes go through `activity.ActivityLogMixin` (put it first in the bases; `activity_category`/`activity_noun`/`activity_fields` give create/update/delete a diffed entry for free, bespoke actions call `self.log(...)`) or `dog_changes.log_activity`. **Only entries with `dog` set appear on that dog's profile** (`?dog=<id>`); no filter is the whole business's log the dashboard's Recent Activity shows the newest few of, minus `STAFF` without `can_manage_staff` and `BILLING` without `can_manage_payments` (`DogChangeLog.RESTRICTED_CATEGORIES`). `?category=`, `?actor=<user id|system>`, `?action=`, `?from=`/`?to=` (inclusive dates) and `?limit=N` narrow it; `actors/` feeds the "changed by" picker — the app's Filters sheet (`widgets/change_log_filter_sheet.dart`) applies all of them server-side. `dog_name` doubles as the entry's `subject` (also exposed as `subject`), names are snapshots and `dog` is SET_NULL, so the trail outlives the dog and an anonymised account. Add the next tracked dog field to `TRACKED_FIELDS`; the next staff action gets a `log`/`log_activity` call beside the write, in its category. |
| `api/staff-availability/` | Staff coverage |
| `api/day-off-requests/` | Staff day-off requests |
| `api/contact-inquiries/` | Website contact form. Both public submit paths (the website view and `api/public/contact-inquiry/`) treat an identical email + message inside `ContactInquiry.DUPLICATE_WINDOW_MINUTES` as the same enquiry: success reply, nothing saved, no second email or push. Sending takes seconds (reCAPTCHA plus a synchronous SMTP send) and people pressed Submit again, so the website button also disables itself on the first press. **The staff badge (`unread_count/`, name kept for older apps) counts `is_replied=False`, not `is_read`:** opening an enquiry marks it read, only Mark as replied clears the badge |
| `api/dog-profile-changes/` | Owner-requested dog profile change requests |
| `api/vaccinations/` | Dog vaccination records |
| `api/vaccination-certificates/` | The vet's certificate behind a dog's vaccination date (PDF or photo). Owners, co-owners and staff list/upload/download for their dogs; removal is the uploader's or staff's; no update. **Files live under `PRIVATE_MEDIA_ROOT`, not `MEDIA_ROOT`, and have no URL** — `<id>/download/` is the only way to the bytes (attachment + nosniff, through the scoped queryset). Images are re-encoded through Pillow (EXIF/GPS stripped, polyglots neutralised); PDFs are sniffed and refused if they carry JavaScript/launch actions/embedded files. 10 MB cap, 25 per dog, uploads throttled 60/hour/user. All of it in `api/certificates.py`. **Every dog carries `certificate_status`** (`Dog.certificate_state`): `MISSING` (nothing filed, since the dog was created), `EXPIRED` (newest certificate evidences a date over a year old — an undated one counts from its upload day) or `OK`, plus `certificate_needed_since`. Anything but OK is what the app nags the owner about — the Needs Your Attention tile, the red strip on the dog's card and the dog profile block all read this one field, and every push about it opens the attach sheet (`type: vaccination_certificate`). The chasing is automatic: `send_vaccination_reminders` pushes the owners the day a lapse is noticed, 3 and 7 days on, then weekly, eight times at most (`Dog.certificate_reminder_*`, re-armed by itself when the lapse date changes and cleared when a certificate arrives); staff can send the same push now from the dashboard's Dog health row (`dogs/<id>/remind_certificate/`, 400 when nobody on the app owns the dog). There is deliberately no booking block behind it. |
| `api/waitlist/` | Daycare waitlist entries |
| `api/vehicles/` | Fleet vehicles (MOT/service tracking) |
| `api/vehicle-defects/` | Vehicle defect reports with photos |
| `api/facility-defects/` | Facility defect reports |
| `api/intake-requests/` | **New Dog** Booking forms (owner dog-intake requests; staff approve to create dogs). The only way a client creates a dog, so `phone_number` and `emergency_contact_number` are required here and copied onto every dog the approval creates. `pending_count/` backs the Booking Forms badge beside the bell and **counts pending link requests too** (`count` = `booking_forms` + `link_requests`), because the app reviews both on one screen (owners get 0). **The form asks for the vet's vaccination certificate per dog** (required in the app): the form is JSON, so the file follows it — `POST <id>/certificate/` (multipart `dog` = IntakeDog id, `file`, optional `vaccination_date`) while the form is pending, stored under `PRIVATE_MEDIA_ROOT` with the same preparation as `vaccination-certificates/`; each dog row carries a `certificate` summary (name/size, null until it arrives, red on the review screen) and `last_vaccination_date`. Approval files it as the new dog's `VaccinationCertificate` and copies the date onto the dog; deny/withdraw delete the file. The welcome push names any dog approved without one |
| `api/dog-link-requests/` | **Link My Dog**: a client whose dog already comes to daycare asks for it to be put on their account, giving the dog's name plus the postcode and phone number staff hold (`DogLinkRequest`). Most of the client book predates the app, so this is the common case; the New Dog form for an existing dog hands staff a duplicate. Staff see `candidates` — existing dogs the client doesn't already own, scored on name/postcode/phone by `serializers.find_link_candidates`, each with `matches` saying why — and `approve/` with `dog=<id>` (any dog, not only a candidate): an ownerless dog gets the client as `owner`, one with an owner gets them as a co-owner (`additional_owners`), a blank `contact_number` is filled from the request. Owners always get `candidates: null` and are never shown any existing dog — a matching name is not proof of ownership. `deny/` takes a `reason`. Pushes: staff with `can_manage_requests` on submit (`notify_new_dog_link_request`), the owner on decision (category `bookings`; `approved` + `dog_id` so the app opens the dog). Logged under `CLIENTS`, source `LINK_REQUEST`, with `dog` set on approval so it shows on the dog's trail |
| `api/invoices/` | Monthly customer invoices (owners view their own — the app shows no Pay button; they pay by bank transfer from the Xero-emailed invoice, and `pay_url/` stays available for a later online-payment switch-on; staff with `can_manage_payments` generate/send/record payments/sync Xero). **Billed in advance:** a month's invoice charges every day the dog is *booked in* that month as the roster stands (`billing.booked_days_for_month` via `ScheduleIndex`: regular days + approved additions − cancellations − removals − closures − boarding days) plus last month's unbilled extras (attended days no invoice has charged). **One line per day**, in date order per dog (`billing._build_all_lines`): last month's unbilled extras come first ("extra day in <month>" in the description), then the month's booked days and boarding nights, each line carrying its single date in `attendance_dates`. A date is charged once, ever — `_billed_dates_by_dog` reads every non-VOID line's `attendance_dates` — so extras added after an invoice went out land on the next month's invoice as their own dated lines. Booked days are charged whether or not the dog turns up. `generate/` takes the month plus optionally one `customer` **or one `dog`** — the per-dog form raises the month in the dog's name whatever its owner status, because most of the client book isn't on the app. **Every generated draft is also raised in Xero as a DRAFT** (against the dog's pinned contact, else a shared "Unassigned (Paws 4 Thought app)" placeholder) so the business can reassign the contact, amend and approve it inside Xero; the 30-minute `sync_xero_invoices` turns that approval into SENT here (adopting Xero's total/due date, booking any difference as an "Amended in Xero" line) and pins the contact the draft ended up on to the dog for next month. Sending from the app approves the same Xero draft. A dog on any active invoice line for a period is never billed again for it, whichever invoice (its own or its owner's) carries it. |
| `api/incidents/` | **Staff-only** incident log — scuffles, bites, injuries, escapes. Tied to the dogs involved (per-dog role/injuries/owner-told), with photos *and* video, follow-up comments and a status. Owners get 403 on every route, including `?dog=<id>` for their own dog. |
| `api/staff-hr/` | **Manager-only** (`can_manage_staff`) employment records: job title, employment dates, holiday allowance, emergency contact, private manager notes. Records are created lazily via `for_staff/?staff_member=<id>` (no create/destroy routes); `team_overview/` returns one summary row per staff member (pay, holiday used/remaining from approved day-off requests, sickness/training/appraisal flags) and excludes the P4TD house account. |
| `api/staff-pay-rates/` | **Manager-only** pay history (hourly or salary, effective-from dated); the latest effective row is a staff member's current pay. |
| `api/staff-meetings/` | Staff meetings (1:1s, team, return-to-work) with attendees, agenda, minutes and status. Managers CRUD; other staff read only meetings they attend. Attendees get a push when added to a scheduled meeting. |
| `api/staff-appraisals/` | Appraisals with a DRAFT → SHARED → ACKNOWLEDGED flow. Managers CRUD + `share/`; the appraised staff member sees their own once shared and may only `comment/` and `acknowledge/`. |
| `api/staff-absences/` | Sickness absences (unplanned — distinct from day-off requests), recorded by managers; staff read their own. Null end_date = still off. |
| `api/staff-training/` | Training/qualification records (e.g. Canine First Aid) with expiry tracking (`expiry_status`: VALID/EXPIRING/EXPIRED/NONE). Managers CRUD; staff read their own. |
| `api/compliance-checks/` | Safety & compliance register: recurring checks (fire alarm tests, extinguisher servicing, first aid kits, licence/insurance renewals) with category, frequency and computed `last_done`/`next_due`/`status` (NEVER_DONE/OVERDUE/DUE_SOON/OK/NONE). All staff read; managing the register needs `can_manage_compliance`. Seeded with UK-typical checks by migration 0083 (only when empty). `?include_inactive=1` shows retired checks. |
| `api/compliance-logs/` | Completions of compliance checks (who/when/PASS-or-ISSUES/notes). Any staff member can log one; editing or deleting a past log is `can_manage_compliance`-only (audit trail). A new log re-arms that check's reminder flags. |

Additional non-router endpoints:
- `api/daycare-settings/` — facility-wide daycare settings
- `api/dogs/<id>/invoice-coverage/` — payment managers only (`can_manage_payments`); which
  invoice charges each of the dog's days, from every non-VOID invoice line's
  `attendance_dates`. Feeds the dog profile calendar's invoice dots (`DogScheduleCalendar`
  `invoiceCoverage`, long-press a day to see and open the invoice); everyone else gets 403
  and the app passes null, so owners and ordinary staff never see it.
- `api/dogs/health_flags/` — staff-only; feeds the dashboard's single **Dog health to
  confirm** row: male dogs over a year old not marked neutered, dogs whose
  `last_vaccination_date` is more than a year old (no date = not flagged), and
  `certificates_missing` — every dog whose `certificate_status` isn't OK, each row with
  the status, since when, when the owner was last reminded and `can_remind` (someone on
  the app owns it) for the row's Remind button — with a grand total.
  `api/dogs/unspayed_males/` is the older half of this and is kept for old app
  versions. Add the next health list here, not as a new dashboard row.
- `api/billing-settings/` — standard prices (payment managers; backed by the website ServicePricing singleton). **Daycare is tiered by how many days a week the dog is booked in** (`Dog.regular_days_per_week`, from `daycare_days`/`schedule_type`): `day_care_price_1_day` (default £40, also ad hoc dogs), `day_care_price_2_to_4_days` (£35), `day_care_price_5_days` (£33). The tier follows the booking, never the month's attendance — a one-day-a-week dog that adds a day pays £40 for both, and the invoice line says which rate applied. Precedence in `billing.resolve_day_rate`: `Dog.daily_rate` (per-dog override, settable only by `can_manage_payments` — `DogViewSet` strips it for everyone else) > the customer's `daycare_rate` > tier. `day_care_price` is the legacy flat rate, kept for older app versions and unused by invoicing.
- `api/customer-rates/` — per-customer billing rate overrides / discounts and billing mode (payment managers). `billing_mode` gates the invoicing transition: `MANUAL` customers (the default) are still invoiced by hand in Xero and skipped by monthly generation; `APP` customers get auto-generated invoices. Explicit single-customer generation bypasses the flag.
- `api/password/reset/request/`, `api/password/reset/verify/`, `api/password/reset/confirm/` — password reset OTP flow
- `api/password/change/` — change password while logged in
- `api/account/email/` — change the signed-in user's email (`new_email` + current `password`).
  Usernames are emails, so the username moves with it when the two match; an account whose
  username is something else keeps it. Names and phone are plain `api/profile/` writes;
  email is not, because it is the login identifier and where reset codes go.
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
- **Custom permissions** via `UserProfile` flags: `can_assign_dogs`, `can_add_feed_media`, `can_manage_requests`, `can_reply_queries`, `can_manage_staff`, `can_view_inquiries`, `can_manage_vehicles`, `can_manage_payments`, `can_manage_boarding`, `can_manage_compliance`. `can_manage_staff` gates the whole Staff Management (HR) section — pay, employment details, meetings, appraisals, sickness and training — as well as working days and day-off approvals. All of these flags (plus `receives_business_alerts`) are toggleable in-app on the superuser-only Staff Permissions screen. The related `receives_business_alerts` flag routes business-owner oversight pushes (e.g. a driver sending a traffic alert) to whoever holds it — normally the business owner; these bypass the staff working-day filter so they arrive even on a day off.
- **Token + Session auth** via djoser — but only two djoser routes are mounted (`p4td_backend/urls.py`): `POST /auth/users/` (sign-up) and `/auth/token/login|logout/`. Do not re-add `include('djoser.urls')`: it brings `/auth/users/me/` (PATCH/DELETE the account, bypassing `delete_account`'s safeguards), `set_username`, and an email-link `reset_password` that 500s because `PASSWORD_RESET_CONFIRM_URL` is unset. Password reset is the OTP flow under `api/password/reset/`.
- **Signals** auto-create `UserProfile` on `User` creation and notify staff on contact inquiries
- **Boarding dogs attend daycare**: approving a stay books its dogs into daycare
  for every weekday it covers — arrival and departure days included — under the
  business's own `P4TD` pseudo-staff account (`api/scheduling.py`:
  `sync_boarding_daycare_assignments`). Cancelling/denying/moving the stay
  releases those rows again; only rows flagged `DailyDogAssignment.from_boarding`
  are ever touched. Billing-neutral by construction —
  `billing.attendance_for_month` already skips days inside an approved stay, so
  the boarding nights are the only charge.
  **Dogs the owner drives both ways go to `P4TD` too** (`owner_brings_default`
  and `owner_collects_default`): `_materialize_roster_for_date` books them there
  every weekday in `daycare_days`, roster entry or not, so they sit on the day's
  board under the house card and never on a driver's list. They used to be
  materialised `UNASSIGNED`, which `today` hides and `unassigned_dogs` hides
  too, so every week the day looked unbooked and staff added them by hand.
  A weekday arrival is the exception: the dog is still at home that morning and
  needs collecting, so that day is created `UNASSIGNED` with no staff member and
  surfaces in `unassigned_dogs` for a driver to claim. It goes to `P4TD` as
  usual when the owner normally brings the dog in themselves
  (`Dog.owner_brings_default`, or the per-date `owner_brings` override), when
  the stay starts at a weekend (by its first weekday the dog is already with the
  carer), or when it runs straight on from another approved stay.
- **A dog's regular days own its future board rows.** The dashboard books a
  dog in the first time anyone looks at a date (`_materialize_roster_for_date`
  writes a `DailyDogAssignment` from `DogWeekdayPickup`), so a change to
  `daycare_days`/`schedule_type` must take those rows back out or the profile
  says Monday while Friday is still on the board and on the invoice. Both
  writers (`DogViewSet.perform_update` and an approved
  `dog-profile-changes/` request) go through `_apply_schedule_change` →
  `scheduling.release_dropped_weekdays`: roster entries for the dropped
  weekdays go, and so do future `ASSIGNED`/`UNASSIGNED` rows on them, except
  boarding rows, approved extra days and days a staff member put the dog on
  by hand (a `SCHEDULE` log entry naming the date). Today's row stays —
  Remove handles the live board. Logged under `SCHEDULE`. Add the next
  schedule writer behind the same helper.
- **Image processing** with Pillow (EXIF rotation, compression, thumbnails)
- **Push notifications** via Firebase Admin SDK. Every owner-facing push carries a
  `category` matched to a `UserProfile.notify_*` switch the person can flip on the
  Profile screen: `feed` (new posts tagged with their dog, comments), `bookings`
  (request decisions), `dog_updates` (collected/arrived and home, sent from
  `daily-assignments/<id>/update_status/` via `notifications.notify_dog_status`),
  `messages` (support-thread replies both ways, plus new-thread alerts to staff with
  `can_reply_queries`), `traffic`. A push with no category cannot be silenced, so
  give new ones a category.
- **Staff inbox pushes** — a Contact Staff message, a booking form, a website
  enquiry — all go through `notifications.notify_staff_inbox`, which pushes the
  staff holding the matching flag (`can_reply_queries` / `can_manage_requests` /
  `can_view_inquiries`) and lifts the working-day filter for anyone with
  `receives_business_alerts`, so the owner hears about a Sunday enquiry on Sunday.
  These are the three counts the app shows beside the bell; route the next
  client-to-business channel through the same helper. Contact Staff pushes are
  sent from `SupportQueryViewSet` only — do not re-add a `post_save` receiver for
  `SupportQuery`/`SupportMessage`, that pair doubled every push.
- **Clients see each other by first name only.** Anything rendered to another
  client (feed comments, reactions, post uploader, push bodies) goes through
  `notifications.public_display_name`, which never falls back to the username —
  usernames are email addresses. Sign-up therefore requires `first_name` and forces
  `username = email`; `api/auth_backends.py` additionally lets an account created
  outside the app sign in with its email. **Staff see clients by full name:** every
  staff-facing `owner_name` field goes through `serializers.owner_display_name`
  ("First Last", else the username), and `owner_details` carries `last_name` so the
  app's `OwnerDetails.displayName` does the same. Never show a bare `username` for
  an owner in the app — it is their email.

### Mobile (Flutter)

- **Services-based architecture**: `DataService`, `AuthService`, `NotificationService`, `CacheService`, `BiometricService`
- **App lock**: opt-in biometric gate (`BiometricService` + `AppLockScreen`) over the
  already-persisted session. Rendered as an overlay in `MaterialApp.builder` so it covers
  every route and leaves the Navigator mounted underneath. Android needs
  `FlutterFragmentActivity` for `local_auth`'s BiometricPrompt.
- **Adding a dog as a client has two doors** (`home_screen.dart` empty state,
  the Booking Forms screen's FAB, and the banner on the form itself): **Link My
  Dog** (`screens/link_dog_screen.dart` → `dog-link-requests/`) for a dog
  already on the books, and the **New Dog Booking Form**
  (`screens/booking_form_screen.dart` → `intake-requests/`) for a new one. Keep
  both visible wherever one is offered — an existing client on the new-dog form
  creates a duplicate dog. Staff review both on `booking_requests_screen.dart`,
  where a link request lists the server's candidate dogs with why each matched
  and a **Find dog** search (`widgets/dog_picker_sheet.dart`) for when none do.
- **Staff dashboard spotlight** (`widgets/spotlight_coach.dart`, steps in
  `unified_dashboard_screen.dart`'s `_spotlightSteps`): on today's board, the
  screen dims except one widget with a speech bubble beside it — the owner
  drop-off card with nobody named (until 11:00), the collection card likewise
  (until 16:00), then unacknowledged grouping conflicts (assigners only).
  Tapping the card or the button does the normal action; the next step follows
  when the day's data changes. Not now hides a step for the session only, so it
  returns on the next launch while still outstanding. The GlobalKeys go on
  today's widgets only — the date switcher keeps the outgoing day mounted for a
  moment and a key may appear once. Add the next must-do-now item as a step
  there, not as another banner.
- **Staff inbox badges**: the home AppBar shows Contact Staff, Booking Forms,
  Website Inquiries (with `can_view_inquiries`) and the bell, each a
  `BadgedActionIcon` (`widgets/badged_action_icon.dart`) with its count. **A count
  clears on action, never on viewing:** a Contact Staff thread until it is replied to
  or resolved, a booking form until approved or denied, an enquiry until marked
  replied, a date-change/boarding request until approved or denied. Opening and
  closing something must never make it disappear from everyone's badge.
  The counts reload on resume and on every push that arrives in the foreground
  (`NotificationService.foregroundMessages`), so a badge is never staler than
  the last time the phone was looked at. The same counts feed the drawer and
  the dashboard's Action Items.
- **Client Dashboard tab** (`screens/client_dashboard_screen.dart`): owners get
  the third tab too, and land on it like staff. Built only from owner-permitted
  calls (`dogs/calendar/`, `boarding-requests/`, `invoices/`,
  `date-change-requests/`, `support-queries/`, `closure-days/`, `feed/?dog=`),
  one section per file under `screens/dashboard/client_*`. The calendar is the
  page; any other fetch failing only degrades its own section. The **Calendar**
  section (`client_calendar_section.dart`) shows all the owner's dogs by Day,
  Week or Month, swiping either way into the past; it owns no data — the
  dashboard seeds it with today's two months and fetches further months from
  `dogs/calendar/` as they scroll into view (the endpoint caps a call at 92
  days). Tapping through opens My Calendar on that day, where the waitlist
  actions live. "Needs Your
  Attention" (`ClientAttention.compute`) lists only items with a count — add
  the next owner-facing nag there, not as a new section. Never surface
  incidents or live pickup status here: both are staff-only over the API.
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

- **Infrastructure**: Hetzner CX22, Docker Compose, Caddy reverse proxy
- **Backend deploy**: automatic — a successful `Backend CI` run on `main` triggers
  `.github/workflows/deploy-backend.yml`, which SSHes to the server, runs `./deploy.sh`,
  and verifies `/healthz/` through Caddy. Manual entry points remain:
  `scripts/deploy-to-hetzner.sh` (from a laptop) or `./deploy.sh` (on the server). All
  pull `main` only, with `--ff-only`, and gate on `/healthz/` before reporting success.
  Because the deploy is gated on `Backend CI`, anything that changes production
  behaviour must appear in that workflow's path filters or it will never ship.
- **Mobile deploy (Android)**: `.github/workflows/deploy-android-alpha.yml` builds
  the AAB and uploads it to the Google Play **alpha** track on every push to `main`
  with `my_app/` changes. Customers get it when a `v*` tag runs
  `.github/workflows/deploy-android-release.yml`, which promotes that same bundle
  (found by pubspec's build number) to production — see
  [Releasing to the stores](#releasing-to-the-stores) below.
- **Mobile deploy (iOS)**: Xcode Cloud archives and uploads to TestFlight on push
  to `main` (bootstrapped by `my_app/ios/ci_scripts/ci_post_clone.sh`). Shipping to
  the App Store is the same `v*` tag, which runs `.github/workflows/deploy-ios-release.yml`
  — see [Releasing to the stores](#releasing-to-the-stores) below. **A tag push starts
  nothing in Xcode Cloud**: the Production workflow (the only one that distributes to
  App Store Connect) must be started for the tag, which the release lane now does
  first thing through the App Store Connect API (`scripts/xcode_cloud_start_build.py`).
  `.github/workflows/xcode-cloud-start-build.yml` is the same step on its own, for a
  tag whose lane died before it.
- **Production server**: Gunicorn (2 workers, 2 threads, 120s timeout)

### Mobile version bumps (required)

**Every commit that changes anything under `my_app/` must bump the version in `my_app/pubspec.yaml`.** The Play Store build fails if the build code (the number after the `+`) is not greater than the previously uploaded one, and so does App Store Connect.

- Format: `version: <major>.<minor>.<patch>+<buildNumber>`
- Default: bump patch and build number by 1 (e.g. `1.7.8+271` → `1.7.9+272`).
- Bump major/minor only when the change warrants it.
- Make the bump part of the same commit as the feature change (or as an immediate follow-up commit before pushing).

### Releasing to the stores

One `v*` tag ships both platforms. Android goes **live on its own**: the tag
promotes the alpha bundle to production, and once Google's review of the update
passes it is in front of every customer — there is no release button to press
afterwards. iOS still needs Apple's approval and then a press in App Store
Connect. So a tag is a release, not a submission: don't tag until the version
is meant to reach customers.

Google Play's What's New is its own file,
`my_app/fastlane/metadata/android/en-GB/changelogs/default.txt`, capped at 500
characters. **The App Store notes are capped too, at 4000 characters** — over
that App Store Connect refuses the whole listing push and the iOS lane dies
before it touches a build. Flutter CI checks both files. Rewrite the Play text
from the same diff as the App Store notes below; the App Store text is far
longer than Play allows, so it cannot simply be copied.

> **What's live — update this when a version is released, not when it is submitted.**
>
> | | Version | pubspec commit | Note |
> |---|---|---|---|
> | Live on the App Store | **1.12.9** | `2c70979` | Tag `v1.12.9`, build 592; confirmed live by Marco on 2026-09-15 |
> | Submitted, in review | 1.12.43 | `4803cad` | Tag `v1.12.43` on 2026-09-20, superseding 1.12.42 (Android build 486 promoted to production; its iOS lane died pushing a 4951-character What's New — Apple caps it at 4000, now checked in Flutter CI) and 1.12.28 (whose iOS submission never went through). Adds vaccination certificate chasing, Link My Dog, the dashboard calendar and the staff dashboard spotlight. Notes diffed from live 1.12.9. **iOS build 622 submitted for review 2026-09-20 22:25** by a re-run of the lane after the tag's own run was refused build 621 (see the Xcode Cloud note under Mobile deploy); Android builds 486 and 487 promoted to production, live once Google's review passes |
>
> **Release notes must be diffed from the live row, never from memory or from
> the last notes file.** Two releases in a row had What's New written against
> a version that was no longer live, re-announcing features customers already
> had. Before touching `my_app/fastlane/metadata/en-GB/release_notes.txt`, list
> what actually changed with
> `git log --no-merges --format='%h %s' <live pubspec commit>..HEAD -- my_app`
> and cover only that. When Apple approves and the version is pressed live in
> App Store Connect, move it into the live row here in the same sitting.
> This table lives in `CLAUDE.md` rather than under `my_app/` because any
> `my_app/**` commit triggers a Play Store upload and needs a version bump.

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
version to finish processing, attaches the newest one, and submits for review. If
App Store Connect refuses that build ("pre-release build could not be added" —
every tag push so far has hit it on the build that was newest at tag time), the
lane waits for the newer build the tag itself queued in Xcode Cloud and retries.
It never builds or uploads a binary itself. Full detail — including the dry-run mode
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
- `PRIVATE_MEDIA_ROOT` — where vaccination certificates are stored (default
  `<repo>/private-media`, bind-mounted in production). Must stay outside `MEDIA_ROOT`
  and outside anything Caddy serves; see `api/certificates.py` and DEPLOYMENT.md.
- Firebase credentials for push notifications. Media is stored on local disk
  (`FileSystemStorage`) and served by Caddy — there is no S3 integration.

## Management Commands

All commands live in `api/management/commands/` (ignore `__init__.py`).

| Command | Purpose | Cron |
|---|---|---|
| `python manage.py import_dogs` | Bulk import dogs from a text file (one name per line) or CSV (`owner_username,dog_name`). `--owner`, `--dry-run` | — |
| `python manage.py seed_demo_data` | Seed/refresh the demo owner account (with a demo dog, gallery, and feed) used for App Store / Play Store screenshots. Idempotent; `--no-media` | — |
| `python manage.py geocode_dogs` | Geocode dog pickup addresses (postcodes.io, free, no API key) and cache lat/lng on each Dog for the staff pickup map. Idempotent; `--dry-run`, `--force`, `--limit`, `--sleep` | — |
| `python manage.py send_vaccination_reminders` | Send push reminders to owners for vaccinations that are expiring or expired. Also, for dogs with no detailed records, one push a week before `Dog.last_vaccination_date` turns a year old (keyed on the date via `annual_vaccination_reminder_sent_for`, so a new date re-arms it). And the **certificate cadence**: while a dog has no current vaccination certificate on file, its owners are pushed the day it is noticed, 3 and 7 days on, then weekly, eight times at most (`Dog.certificate_reminder_*`; a certificate arriving clears it, a new lapse restarts it). Dogs nobody on the app owns are skipped — they stay on the dashboard for a phone call | Daily 8:00am |
| `python manage.py send_fleet_reminders` | Push MOT/service due reminders to staff with `can_manage_vehicles` | Daily 8:05am |
| `python manage.py send_compliance_reminders` | Push due/overdue safety & compliance check reminders to staff with `can_manage_compliance` — 30 days ahead for long-cycle checks, plus at due/overdue; once per cycle, re-armed when a completion is logged | Daily 8:10am |
| `python manage.py send_end_of_day_alerts` | Push an end-of-day exception summary (dogs never picked up, still out with the team, or never assigned to a driver) to staff with `receives_business_alerts`. Silent when everything got home. `--date` | Daily 5:30pm |
| `python manage.py prune_feed_media` | Delete old feed media (GroupMedia) and optionally remove orphaned files. Never touches dog gallery photos — see [Feed Media Pruning](#feed-media-pruning) | Weekly, Sun 3am (with `--include-orphans`) |
| `python manage.py release_stale_roster_days` | Take dogs off future days still booked from a regular weekday they no longer come on (rows the dashboard materialised before the schedule edit released them itself — see the roster note under Backend). Lists by default; `--apply` deletes, `--dog <id>` narrows. Same exclusions as the edit | — |
| `python manage.py prune_device_tokens` | Delete stale push-notification device tokens not refreshed in N days (default 90); live devices re-register on launch. `--days`, `--dry-run` | — |
| `python manage.py prune_auth_tokens` | Delete DRF auth tokens older than N days so an abandoned device's token can't be reused indefinitely (tokens never expire on their own). `--days`, `--dry-run` | — |
| `python manage.py generate_monthly_invoices` | Generate draft invoices for the current month in advance (its booked days plus last month's unbilled extras); notifies staff with `can_manage_payments` to review/send. Idempotent; `--year`, `--month` | Monthly, 1st 6:00am |
| `python manage.py sync_xero_invoices` | Pull status back from Xero: drafts approved there become SENT (deleted there become VOID), and payments on open invoices are imported (no-op when Xero not connected) | Every 30 min |
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
so a `Photo` row is a record, not a snapshot: it goes only when a staff member
deletes that photo (owners get 403 — see `PhotoViewSet.perform_destroy`) or
when the dog itself is deleted (`DogViewSet.destroy` clears the files with it).
Do not add `Photo` to the retention pass. `--include-orphans` does sweep
`dog_photos/`, but only as a backstop for files whose row is already gone — and
before it removes anything, a file must be absent from the reference snapshot,
be older than `--orphan-grace-hours` (default 24, since Django writes an upload
to disk before committing its row), *and* still be unreferenced on a second
database check taken after the directory walk.

## Important Notes

- The `app/` directory is a **legacy Android app** — the active mobile client is `my_app/` (Flutter)
- No backend linter is configured — follow standard Django/PEP 8 conventions
- Media files, `private-media/` and `.env` are gitignored
- **`/media/` is public.** Anything under `MEDIA_ROOT` is served to anyone with the
  link, with no authentication. Paperwork that identifies a person (vaccination
  certificates today) goes under `PRIVATE_MEDIA_ROOT` behind a gated download view
  instead — copy the `VaccinationCertificate` pattern in `api/certificates.py` rather
  than adding another `FileField(upload_to=...)`.
- Line endings: LF enforced for `.sh` files via `.gitattributes`
- CI: `backend-ci.yml` (Django checks + full suite against PostgreSQL 15, plus a dependency
  audit and a Docker build), `flutter-ci.yml` (analyze + test + pubspec version-bump check
  + the [Flutter pin guard](#flutter-version-pin)),
  `deploy-android-alpha.yml` (Play Store alpha upload), `store-screenshots.yml` (manual),
  `app-store-metadata.yml` (manual — pushes the App Store listing text from
  `my_app/fastlane/metadata/`; see `my_app/STORE_METADATA.md`),
  `deploy-ios-release.yml` (on a `v*` tag — pushes the listing, attaches the
  Xcode Cloud build for that commit, and submits it for App Review),
  `deploy-android-release.yml` (on the same `v*` tag — promotes that version's
  alpha bundle to the Google Play production track),
  `deploy-backend.yml` (production deploy, triggered by a green `Backend CI` on `main`).
