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

## Batch 2 — Backend correctness / bugs ✅ (236 tests OK; migration 0056)
- [x] **B11** 🟡 M — Make capacity check + approval transactional (overbooking race)
- [x] **B12** 🟡 S — Wrap date-change approval side effects in transaction; notify after commit
- [x] **B14** ⚪ M — Closed-day guard on direct assign actions (capacity is enforced at the scheduling layer, not when assigning already-scheduled dogs)
- [x] **B15** 🟡 S — Comment FK pair CheckConstraint (exactly one parent)
- [x] **B16** 🟡 S — DayOffRequest (staff,date) conditional UniqueConstraint + IntegrityError guard
- [x] **B18** 🟡 M — Validate `Dog.daycare_days` (unique sorted ints 1–7) in serializer
- [x] **B24** ⚪ S — `set_my_availability`: coerce stringly-typed day_of_week/is_available
- [x] **B25** ⚪ S — Validate request_type/date coherence in serializer
- [x] **B26** ⚪ S — react/comment re-fetch via `_feed_queryset` (add_message already used base manager)
- [x] **B27** ⚪ S — `swap_staff`: coerce ids before equality check
- [x] **B28** ⚪ S — `BoardingRequestSerializer.validate`: handle partial updates
- [x] **B30** 🟡 S — Feed ordering `-id` tie-breaker (queryset + model Meta)
- [x] **B41** 🟡 S — `approve_requests` admin action: transactional

## Batch 3 — Backend performance & queries ✅ (236 tests OK; migration 0057)
- [x] **B5** 🟠 S — Dog queryset select_related/prefetch owner profiles; explicit except in serializer
- [→] **B6** 🟠 M — Pagination deferred to Batch 9 (needs coordinated Flutter client change)
- [x] **B7** 🟠 M — `is_boarding` via per-date context set (today/my_assignments); query fallback elsewhere
- [x] **B8** 🟠 S — Documented select_related('dog') requirement on effective_* (viewsets already do it)
- [x] **B9** 🟠 M — Notification fan-out deferred via on_commit + daemon thread
- [x] **B10** 🟡 S — Firebase `send_each` batch API
- [~] **B17** 🟡 S — Already covered: Django auto-indexes FK columns (audit premise was wrong); no change needed
- [x] **B21** ⚪ S — Dropped the save-profile-on-every-User-save signal
- [x] **B29** 🟡 S — SupportQuery count/last-message read from prefetch cache
- [x] **B31** 🟡 L — Single-decode image pair for feed + dog photos (full async needs a task queue — deferred)
- [x] **B32** 🟡 M — Inline geocode kept but provider timeout lowered to 4s + honest docstring (true async breaks the sync test contract)
- [x] **B33** 🟡 S — Added `prune_device_tokens` command (cross-user already handled by unique token + reassignment)
- [x] **B36** ⚪ S — `geocode_dogs` streams with iterator() and stops at --limit
- [x] **B38** 🟠 S — `DailyDogAssignment` admin: list_select_related + RelatedOnlyFieldListFilter
- [x] **B39** 🟡 S — Admin changelists: annotated counts, prefetch, RelatedOnlyFieldListFilter
- [x] **B40** ⚪ M — list_select_related across single-FK admins
- [x] **B23** ⚪ S — Prune used PasswordResetOTP; index (user,is_used)
- [x] **B37** ⚪ S — notifications use logging instead of print()

## Batch 4 — Backend data-model / maintainability / integrations ✅ (236 tests OK)
- [x] **B20** 🟡 M — delete_account promotes a co-owner to owner; admin orphan filter for the rest
- [x] **B22** ⚪ M — Re-arm reminder flags centrally in VaccinationRecord/Vehicle save()
- [x] **B34** ⚪ M — Reminder crons set the flag before dispatch (at-most-once)
- [x] **B35** ⚪ S — `geocode_dogs` help text says postcodes.io
- [x] **B43** 🟡 M — `prune_auth_tokens` command (cron purge) + B3 rotation on password change

## Batch 5 — Backend tests
- [ ] **B46** 🟠 M — Tests: password reset / change / delete-account flows
- [ ] **B47** 🟡 S — Tests: DeviceToken viewset + cross-user reassignment
- [ ] **B48** 🟡 S — Tests: daycare_settings PATCH auth/validation
- [ ] **B49** 🟡 M — Tests: object-level cross-owner (IDOR) access
- [ ] **B50** 🟡 S — Tests: get_owner/update_owner negative paths
- [ ] **B51** ⚪ S — Tests: postcode_lookup branches
- [ ] **B52** ⚪ M — Tests: auto_assign/suggested/reorder/send_traffic_alert
- [ ] **B53** ⚪ S — Tests: defect notification reporter self-skip

## Batch 6 — Website ✅ (20 website tests OK; migration 0008 = help_text only)
- [x] **W1** 🟡 S — Captcha field dropped when key blank (forms.py)
- [x] **W2** 🟡 M — Cache-based per-IP throttle + honeypot + message max_length
- [x] **W3** 🟡 M — nh3 sanitization in BlogPost/SiteSettings save()
- [x] **W4** 🟡 M — website/tests.py (20 tests)
- [x] **W5** ⚪ S — EmailMessage reply_to + optional CONTACT_INQUIRY_EMAIL recipient
- [x] **W6** ⚪ S — services added to sitemap (+ fixed BlogPost.get_absolute_url)
- [x] **W7** ⚪ S — Cached SiteSettings/ServicePricing singletons, invalidated on save
- [x] **W8** ⚪ S — Blog unpublish filters to published + reports count

## Batch 7 — Infra / config ✅ (check clean DEBUG on+off; YAML+shell validated)
- [x] **I2** 🟠 S — `.github/workflows/backend-ci.yml` (postgres service, test + makemigrations --check)
- [x] **I4** 🟠 S — Enabled HTTPS flags (Secure cookies, HttpOnly, SSL redirect, HSTS)
- [x] **I5** 🟠 M — requirements-prod `-r requirements.txt` + pins; dropped dead django-storages/boto3; added nh3, sentry-sdk
- [x] **I6** 🟠 M — Optional Sentry guarded by SENTRY_DSN (try/except import)
- [x] **I8** 🟡 S — Removed prod `8000:8000` publish
- [x] **I9** 🟡 S — Caddyfile uses `{$DOMAIN_NAME}` for auto-HTTPS *(deploy: set DOMAIN_NAME)*
- [x] **I10** 🟡 S — Added `.dockerignore`
- [x] **I11** 🟡 S — DEBUG no longer a runtime ENV (inline on collectstatic RUN)
- [x] **I12** 🟡 S — `/healthz/` endpoint + compose healthcheck
- [x] **I14** ⚪ S — Dev compose param password + PG bound to 127.0.0.1
- [x] **I15** ⚪ S — Dockerfile HEALTHCHECK → /healthz/
- [x] **I16** ⚪ S — Gunicorn `--max-requests 1000 --max-requests-jitter 100`
- [x] **I17** ⚪ S — Standardised prod media on named volume `media_data` *(deploy: migrate media)*
- [x] **I13** 🟡 M — Deploy script: readiness loop + post-migrate health gate + rollback record *(deploy)*
- [x] **I1** 🔴 M — `scripts/backup-db.sh` nightly pg_dump + retention *(deploy: cron + off-box ship)*
- [→] **B44** ⚪ S — Kept localhost for healthcheck; risk mitigated by I8 + OTP-based reset (documented)
- [ ] **I7** 🟡 M — Cron failure alerting — NOT done (folds into the deploy cron wiring; see notes)
- [ ] **I3** 🟠 M — Authenticated media — DEFERRED (needs coordinated Flutter image-auth or signed URLs; would break all image loading if done piecemeal)

## Batch 8 — Docs ✅
- [x] **D1** 🟠 S — Removed non-existent `breed` field (FUNCTIONALITY_GUIDE had none)
- [x] **D2** 🟡 S — Fixed permission-flag list in CLAUDE.md (real seven flags)
- [x] **D3** 🟡 S — Added missing endpoints to CLAUDE.md table + source-of-truth note
- [x] **D4** 🟡 S — Rebuilt management-commands table with cron column
- [x] **D5** 🟡 S — Fixed icon library (picons, not Phosphor)
- [x] **D6** ⚪ S — Noted prune cron runs `--include-orphans`
- [x] **D7** ⚪ S — Documented POSTCODE_LOOKUP_API_KEY
- [x] **D8** ⚪ S — Added schedule_type + real field list to integration doc
- [x] **D9** ⚪ S — Fixed Dart SDK constraint (>=3.3.0 <4.0.0)
- [x] **D10** ⚪ S — Real project `my_app/README.md`
- [x] **D11** ⚪ M — Expanded root README (3 components, tests, links)

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

Server-side actions that can't be done from the repo:

1. **I9 — DOMAIN_NAME**: set `DOMAIN_NAME` in the deploy env/`.env` so Caddy provisions the right cert (falls back to `paws4thoughtdogs.com`). `setup-hetzner.sh` already writes it into the generated `.env`.
2. **I17 — media volume migration**: prod switched from the `./media` bind-mount to the named volume `media_data`. On the next deploy, copy existing media into the `p4td_media_data` volume once; if Caddy is a separate container, mount `media_data` at `/srv/media` (read-only).
3. **I1 — backups**: wire `scripts/backup-db.sh` to host cron and configure off-box shipping (rclone/restic/S3).
4. **I7 — cron alerting**: add a heartbeat (e.g. healthchecks.io ping) to the cron entries for backups + reminders so silent failures surface.
5. **I13 — rollback**: automated rollback isn't performed; the deploy script records the prior commit + image id to `.deploy-history` and prints the manual rollback command.
6. **CONTACT_INQUIRY_EMAIL** (W5): set this to route contact-form inquiries to a monitored inbox (falls back to DEFAULT_FROM_EMAIL).
7. **Constraint migrations** (B15/B16): the Comment "exactly one parent" CheckConstraint and the DayOffRequest active-uniqueness constraint will fail to apply if existing prod rows already violate them — dedupe first if `migrate` errors.

## Deferred / follow-up (not done this pass)

- **I3 — authenticated private media** 🟠: dog/staff/defect photos are still served without auth. Doing this right needs a coordinated change: serve via an auth-checking Django view with `X-Accel-Redirect`/Caddy internal (or move to S3 signed URLs), AND update the Flutter app to send the token with image requests (CachedNetworkImage `httpHeaders`) — otherwise every image breaks. UUID-randomising new upload filenames is a low-risk partial mitigation worth doing first.
- **B6 — list pagination** 🟠: deferred; needs the Flutter client to follow paginated responses (Batch 9/10 scope).
- **Flutter batches 9 & 10**: see below — partially done (security/correctness items); the larger perf + refactor items remain.
