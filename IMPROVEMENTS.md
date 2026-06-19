# Improvement Audit — Execution Tracker

Master checklist for the codebase-wide improvement audit (79 items). Worked through
autonomously on branch `improvements-audit`, one commit per batch.

## Process (per batch)

1. Implement every item in the batch.
2. Verify: backend → `DJANGO_DEBUG=true python manage.py test` (+ `manage.py check`);
   Flutter → `flutter analyze` (and `flutter test` where relevant). Baseline analyze ≈ 404 infos.
3. Bump `my_app/pubspec.yaml` version on any batch touching `my_app/`.
4. Commit with a message listing the IDs done.
5. Tick the items here.

Severity: 🔴 critical · 🟠 high · 🟡 medium · ⚪ low. Effort: S/M/L.

---

## Batch 1 — Backend security quick wins ✅ (236 tests OK)
- [x] **B1** 🔴 S — Lock permission flags out of self-service `/api/profile/` (read_only_fields)
- [x] **B2** 🟠 S — Compute `is_charged` server-side; read-only for non-staff
- [x] **B3** 🟠 S — `change_password`: verify old password + rotate token *(needs Flutter: old-password field + store rotated token — see Batch 9)*
- [x] **B4** 🟠 S — Scope `DayOffRequest` queryset; gate retrieve/update
- [x] **B13** 🟡 S — `bulk_import` dog endpoint: add staff-only check
- [x] **B19** ⚪ S — Re-enforce ALLOWED_FIELDS whitelist in change-request approve; `proposed_changes` read-only
- [x] **B42** ⚪ S — Remove permission flags from admin `list_editable`; add list_per_page
- [→] **B44** ⚪ S — Moved to Batch 7 (entangled with /healthz host header)
- [x] **B45** ⚪ S — Don't derive CORS allow-all from DEBUG; warn loudly

## Batch 2 — Backend correctness / bugs
- [ ] **B11** 🟡 M — Make capacity check + approval transactional (overbooking race)
- [ ] **B12** 🟡 S — Wrap date-change approval side effects in transaction; notify after commit
- [ ] **B14** ⚪ M — Add capacity/closure guards to direct assign actions
- [ ] **B15** 🟡 S — Comment FK pair CheckConstraint (exactly one parent)
- [ ] **B16** 🟡 S — DayOffRequest (staff,date) conditional UniqueConstraint
- [ ] **B18** 🟡 M — Validate `Dog.daycare_days` (unique ints 1–7)
- [ ] **B24** ⚪ S — `set_my_availability`: coerce stringly-typed day_of_week
- [ ] **B25** ⚪ S — Validate request_type/date coherence in serializer
- [ ] **B26** ⚪ S — react/comment/add_message: re-fetch from base manager
- [ ] **B27** ⚪ S — `swap_staff`: coerce ids before equality check
- [ ] **B28** ⚪ S — `BoardingRequestSerializer.validate`: handle partial updates
- [ ] **B30** 🟡 S — Feed pagination: add `-id` tie-breaker
- [ ] **B41** 🟡 S — `approve_requests` admin action: transactional + confirmation

## Batch 3 — Backend performance & queries
- [ ] **B5** 🟠 S — Dog queryset select_related/prefetch owner profiles; fix bare except
- [ ] **B6** 🟠 M — Paginate high-volume list endpoints (coordinate Flutter client)
- [ ] **B7** 🟠 M — `is_boarding`: compute boarding ids once via context/annotation
- [ ] **B8** 🟠 S — Ensure select_related('dog') for effective_* paths
- [ ] **B9** 🟠 M — Defer notification fan-out to on_commit/background
- [ ] **B10** 🟡 S — Use firebase `send_each` batch API
- [ ] **B17** 🟡 S — Add indexes on heavily-joined FKs
- [ ] **B21** ⚪ S — `save_user_profile`: only create on created=True
- [ ] **B29** 🟡 S — SupportQuery list: annotate count/last-message
- [ ] **B31** 🟡 L — Move image/video processing off request path (or single-resize)
- [ ] **B32** 🟡 M — Geocode after response (on_commit); fix docstring
- [ ] **B33** 🟡 S — FCM token age-pruning + cross-user dedupe on register
- [ ] **B36** ⚪ S — `geocode_dogs`: iterator()/only(), queryset-level limit
- [ ] **B38** 🟠 S — `DailyDogAssignment` admin: list_select_related
- [ ] **B39** 🟡 S — Admin changelists: annotate counts, prefetch, RelatedOnlyFieldListFilter
- [ ] **B40** ⚪ M — Add list_select_related across single-FK admins
- [ ] **B23** ⚪ S — Prune PasswordResetOTP; index (user,is_used)
- [ ] **B37** ⚪ S — Replace `print()` in notifications with logging

## Batch 4 — Backend data-model / maintainability / integrations
- [ ] **B20** 🟡 M — Dog.owner deletion lifecycle (cleanup or admin filter for orphans)
- [ ] **B22** ⚪ M — Centralise reminder-flag re-arm in save()/signal
- [ ] **B34** ⚪ M — Reminder crons: set flag before/with dispatch; lock
- [ ] **B35** ⚪ S — `geocode_dogs`: fix help text/counters (postcodes.io)
- [ ] **B43** 🟡 M — Token lifecycle (expiry/rotation + purge job)

## Batch 5 — Backend tests
- [ ] **B46** 🟠 M — Tests: password reset / change / delete-account flows
- [ ] **B47** 🟡 S — Tests: DeviceToken viewset + cross-user reassignment
- [ ] **B48** 🟡 S — Tests: daycare_settings PATCH auth/validation
- [ ] **B49** 🟡 M — Tests: object-level cross-owner (IDOR) access
- [ ] **B50** 🟡 S — Tests: get_owner/update_owner negative paths
- [ ] **B51** ⚪ S — Tests: postcode_lookup branches
- [ ] **B52** ⚪ M — Tests: auto_assign/suggested/reorder/send_traffic_alert
- [ ] **B53** ⚪ S — Tests: defect notification reporter self-skip

## Batch 6 — Website
- [ ] **W1** 🟡 S — Contact form: guard blank reCAPTCHA keys / system check
- [ ] **W2** 🟡 M — Contact form: rate limit + honeypot + message max_length
- [ ] **W3** 🟡 M — Sanitize admin rich-text HTML on save (nh3/bleach)
- [ ] **W4** 🟡 M — Add website tests
- [ ] **W5** ⚪ S — Inquiry emails: reply_to + monitored recipient
- [ ] **W6** ⚪ S — Add services page to sitemap
- [ ] **W7** ⚪ S — Cache singleton `.load()` rows / cache_page
- [ ] **W8** ⚪ S — Blog unpublish action: status filter + count

## Batch 7 — Infra / config (repo changes; deploy steps flagged)
- [ ] **I2** 🟠 S — Backend CI workflow (postgres service, test + makemigrations --check)
- [ ] **I4** 🟠 S — Enable HTTPS flags (Secure cookies, SSL redirect, HSTS)
- [ ] **I5** 🟠 M — Consolidate requirements (`-r`) + pin; drop dead django-storages/boto3
- [ ] **I6** 🟠 M — Add Sentry (guarded by SENTRY_DSN env)
- [ ] **I8** 🟡 S — Don't publish prod 8000 to 0.0.0.0
- [ ] **I9** 🟡 S — Caddyfile: real site address for auto-HTTPS *(deploy)*
- [ ] **I10** 🟡 S — Add `.dockerignore`
- [ ] **I11** 🟡 S — Don't bake DJANGO_DEBUG=True as runtime ENV
- [ ] **I12** 🟡 S — `/healthz` endpoint + compose healthcheck
- [ ] **I14** ⚪ S — Dev compose: param Postgres password; bind PG to localhost
- [ ] **I15** ⚪ S — Point Dockerfile HEALTHCHECK at /healthz (with I12)
- [ ] **I16** ⚪ S — Gunicorn: --max-requests + jitter
- [ ] **I17** ⚪ S — Standardise prod media location *(deploy)*
- [ ] **I13** 🟡 M — Deploy script: rollback + health gate + readiness loop *(deploy)*
- [ ] **I7** 🟡 M — Cron failure alerting (heartbeat/non-zero exit) *(deploy)*
- [ ] **I1** 🔴 M — Nightly off-box pg_dump backup script *(deploy)*
- [ ] **I3** 🟠 M — Authenticated media serving (X-Accel/internal) *(deploy)*

## Batch 8 — Docs
- [ ] **D1** 🟠 S — Remove non-existent `breed` field from docs
- [ ] **D2** 🟡 S — Fix permission-flag list in CLAUDE.md
- [ ] **D3** 🟡 S — Add missing endpoints to CLAUDE.md table
- [ ] **D4** 🟡 S — Add missing management commands to CLAUDE.md
- [ ] **D5** 🟡 S — Fix icon library (picons, not Phosphor)
- [ ] **D6** ⚪ S — Note prune cron runs `--include-orphans`
- [ ] **D7** ⚪ S — Document POSTCODE_LOOKUP_API_KEY
- [ ] **D8** ⚪ S — Add schedule_type to integration doc
- [ ] **D9** ⚪ S — Fix Dart SDK constraint (>=3.3.0)
- [ ] **D10** ⚪ S — Real `my_app/README.md`
- [ ] **D11** ⚪ M — Expand root README (3 components, tests, links)

## Batch 9 — Flutter security / correctness / performance (small–medium)
- [ ] **F1** 🟠 S — Re-enable TLS enforcement (iOS ATS, Android cleartext); drop stale IP
- [ ] **F2** 🟠 M — HTTP timeouts on all data_service calls (central client)
- [ ] **F3** 🟠 M — 401/403 handling → auto sign-out; typed exceptions
- [ ] **F5** 🟡 S — `_getHeaders`: throw on null token, not `Token null`
- [ ] **F6** 🟡 S — `uploadMultiplePhotos`: continue on failure, report partials
- [ ] **F7** 🟡 S — Notification payload: jsonEncode/Decode
- [ ] **F8** 🟡 S — Feed actions: `mounted` guard after await
- [ ] **F4** 🟡 M — Encrypt Hive box (HiveAesCipher key in secure storage)
- [ ] **F9** 🟠 S — Gallery grid: use thumbnailUrl + memCacheWidth
- [ ] **F10** 🟠 M — memCacheWidth on feed/list CachedNetworkImages
- [ ] **F19** 🟡 M — `all_dogs_today`: ListView.builder
- [ ] **F20** 🟡 S — Map route anim: stop when idle/paused; precompute lengths
- [ ] **F21** 🟡 S — Video player: ValueListenableBuilder for time text
- [ ] **F22** 🟡 M — Feed: ValueKey, debounce search, cache filtered list
- [ ] **F25** 🟡 S — Dispose text controllers (8+ screens)
- [ ] **F23** ⚪ M — Feed scrollToPost: ensureVisible instead of 450px estimate
- [ ] **F24** ⚪ M — Feed JSON parse off main isolate (compute)
- [ ] **F26** ⚪ M — Map `_assign`: refresh + scope prompt parity
- [ ] **F27** ⚪ S — Auth errors: friendly messages, log raw in debug only
- [ ] **F28** ⚪ S — Multi-account blob: validate + log decode errors
- [ ] **F29** ⚪ S — Login: client-side validation
- [ ] **F30** ⚪ S — Register: stronger email regex, inline match check
- [ ] **F31** ⚪ S — Theme-derived text colours (dark mode)

## Batch 10 — Flutter large refactors
- [ ] **F18** 🟡 L — Extract ApiClient (headers/timeout/status mapping/decode); enables F2/F3/F5
- [ ] **F11** 🟠 L — Route screens through `getIt<DataService>()`
- [ ] **F12** 🟠 L — Shared AssignmentActions controller/mixin (4 screens)
- [ ] **F13** 🟠 M — Shared media-upload flow (feed + dashboard)
- [ ] **F16** 🟡 M — Shared AssignmentCard widget
- [ ] **F14** 🟡 L — Decompose UnifiedDashboardScreen
- [ ] **F15** 🟡 L — Decompose DogHomeScreen
- [ ] **F17** ⚪ M — DayData value object for dashboard caches

---

## Manual deploy steps (to run after merge)

Collected here as items are implemented — server-side actions I can't perform from the repo.

_(populated during Batch 7)_
