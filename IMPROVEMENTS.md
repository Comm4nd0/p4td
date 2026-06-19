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

## Batch 5 — Backend tests ✅ (290 tests OK, +54 new)
- [x] **B46** 🟠 M — Tests: password reset / change (old_password + token rotation) / delete-account (co-owner promotion)
- [x] **B47** 🟡 S — Tests: DeviceToken viewset + cross-user reassignment
- [x] **B48** 🟡 S — Tests: daycare_settings PATCH auth/validation
- [x] **B49** 🟡 M — Tests: object-level cross-owner (IDOR) access
- [x] **B50** 🟡 S — Tests: get_owner/update_owner negative paths
- [x] **B51** ⚪ S — Tests: postcode_lookup branches
- [x] **B52** ⚪ M — Tests: auto_assign/suggested/reorder/send_traffic_alert
- [x] **B53** ⚪ S — Tests: defect notification reporter self-skip

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
- [x] **I7** 🟡 M — Cron heartbeat (api/cron_heartbeat.py) wired into reminder + prune commands; pings P4TD_CRON_HEARTBEAT_URL on success *(deploy: set the env var + a healthchecks.io check)*
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

## Batch 9 — Flutter security / correctness / performance ✅ mostly (analyze clean)
- [x] **F1** 🟠 S — Re-enable TLS enforcement (iOS ATS, Android cleartext); dropped stale IP
- [x] **F2** 🟠 M — 30s timeout in http_client wrapper (covers all data_service/auth calls)
- [x] **F3** 🟠 M — http_client onUnauthorized on 401 → main.dart signs out + routes to login (403 left as permission-denied)
- [x] **F5** 🟡 S — `_getHeaders` omits Authorization when no token
- [x] **F6** 🟡 S — `uploadMultiplePhotos` continues on failure; errors only if none succeed
- [x] **F7** 🟡 S — Notification payload jsonEncode/Decode
- [x] **F8** 🟡 S — Feed actions `mounted` guard after await
- [x] **F4** 🟡 M — Encrypt Hive box (HiveAesCipher key in secure storage)
- [x] **F9** 🟠 S — Gallery grid thumbnailUrl + memCacheWidth
- [x] **F10** 🟠 M — memCacheWidth/Height on feed/list/avatar images
- [x] **F19** 🟡 M — `all_dogs_today` ListView.builder
- [ ] **F20** 🟡 S — Map route anim stop-when-idle — NOT done (pickup_map_screen.dart has local WIP; left untouched)
- [x] **F21** 🟡 S — Video player ValueListenableBuilder for time text
- [x] **F22** 🟡 M — Feed ValueKey + debounced search + cached filter
- [x] **F25** 🟡 S — Dispose controllers across 8+ screens/dialogs
- [x] **F23** ⚪ M — Feed scrollToPost via GlobalKey + ensureVisible (dev branch)
- [x] **F24** ⚪ M — Feed JSON parsed off the main isolate via compute() (dev branch; optimistic-comment micro-part skipped)
- [ ] **F26** ⚪ M — Map `_assign` refresh/scope — NOT done (pickup_map WIP)
- [x] **F27** ⚪ S — Auth errors friendly + debug-only raw log
- [x] **F28** ⚪ S — Multi-account blob validate + log + drop bad entry
- [x] **F29** ⚪ S — Login client-side validation
- [x] **F30** ⚪ S — Register stronger email regex + inline match
- [x] **F31** ⚪ S — Theme-derived text colours (dark mode)

## Batch 10 — Flutter large refactors — NOT done (documented follow-up)
Large architectural rewrites of working code that can't be runtime-verified here
(no device/emulator); attempting them unverified risks logic/UI regressions
`flutter analyze` won't catch. Recommended as a focused, separately-reviewed pass.
Note F18's *goal* (centralise HTTP cross-cutting concerns) is partially met:
http_client now owns timeouts (F2) + 401 handling (F3) for every call.
- [ ] **F18** 🟡 L — Full ApiClient extraction / split the 116-method god-class into repositories
- [x] **F11** 🟠 L — Routed 38 screens/widgets through `getIt<DataService>()` (+3 interface methods); analyze 0/0, 37 tests pass
- [ ] **F12** 🟠 L — Shared AssignmentActions controller (touches pickup_map WIP)
- [x] **F13** 🟠 M — Shared MediaUploadFlow (feed + dashboard) (dev branch)
- [ ] **F16** 🟡 M — Shared AssignmentCard widget (touches pickup_map WIP)
- [ ] **F14** 🟡 L — Decompose UnifiedDashboardScreen (2090 lines)
- [ ] **F15** 🟡 L — Decompose DogHomeScreen (1770 lines)
- [x] **F17** ⚪ M — DayData value object for dashboard caches (dev branch)

## Also deferred
- [ ] **B6** 🟠 M — List pagination (coordinated backend + Flutter client)
- [~] **I3** 🟠 M — UUID filenames for processed-image uploads done (unguessable URLs); full auth-gating still deferred (needs coordinated Flutter image-auth / signed URLs). Video files still keep original names.
- [ ] **I7** 🟡 M — Cron failure alerting (folds into deploy cron wiring)

---

## Manual deploy steps (to run after merge)

Server-side actions that can't be done from the repo:

1. **I9 — DOMAIN_NAME**: set `DOMAIN_NAME` in the deploy env/`.env` so Caddy provisions the right cert (falls back to `paws4thoughtdogs.com`). `setup-hetzner.sh` already writes it into the generated `.env`.
2. **I17 — media volume migration**: prod switched from the `./media` bind-mount to the named volume `media_data`. On the next deploy, copy existing media into the `p4td_media_data` volume once; if Caddy is a separate container, mount `media_data` at `/srv/media` (read-only).
3. **I1 — backups**: wire `scripts/backup-db.sh` to host cron and configure off-box shipping (rclone/restic/S3).
4. **I7 — cron alerting**: the commands now ping `P4TD_CRON_HEARTBEAT_URL` on success — set that env var to a healthchecks.io (or similar) check so a missed ping alerts you. Add a check for backups too.
5. **I13 — rollback**: automated rollback isn't performed; the deploy script records the prior commit + image id to `.deploy-history` and prints the manual rollback command.
6. **CONTACT_INQUIRY_EMAIL** (W5): set this to route contact-form inquiries to a monitored inbox (falls back to DEFAULT_FROM_EMAIL).
7. **Constraint migrations** (B15/B16): the Comment "exactly one parent" CheckConstraint and the DayOffRequest active-uniqueness constraint will fail to apply if existing prod rows already violate them — dedupe first if `migrate` errors.

## Deferred / follow-up (not done this pass)

- **I3 — authenticated private media** 🟠: dog/staff/defect photos are still served without auth. Doing this right needs a coordinated change: serve via an auth-checking Django view with `X-Accel-Redirect`/Caddy internal (or move to S3 signed URLs), AND update the Flutter app to send the token with image requests (CachedNetworkImage `httpHeaders`) — otherwise every image breaks. UUID-randomising new upload filenames is a low-risk partial mitigation worth doing first.
- **B6 — list pagination** 🟠: deferred; needs the Flutter client to follow paginated responses (Batch 9/10 scope).
- **Flutter batches 9 & 10**: see below — partially done (security/correctness items); the larger perf + refactor items remain.
