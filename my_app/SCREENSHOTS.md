# Store screenshots — automated

Generate App Store **and** Play Store screenshots from one Flutter integration
test and upload them — no manual capturing on each device.

How it works: the test signs in as a **demo owner account** on the real backend
and walks the key owner screens, taking a screenshot at each. A script runs that
test across the required device sizes; fastlane then uploads them.

```
seed demo data ──► capture (per device) ──► upload
 (Django cmd)        tool/screenshots.sh      fastlane upload_*
```

> **Plain screenshots, no framing.** The shots are uploaded as captured — no
> device bezels and no captions burned onto the image. `frameit` has no frames
> for the emulator/simulator resolutions we capture at, so framing was removed.
> `fastlane/captions.strings` is kept only as suggested store-listing copy you
> can paste into App Store Connect / Play Console by hand.

## Two ways to run it

- **GitHub Actions (no Mac needed — use this on Windows).** The
  `Store Screenshots` workflow generates **both** platforms on cloud runners
  (iOS on macOS, Android on Ubuntu) and uploads them. See
  [§ CI](#ci-github-actions--no-mac-needed) below. iOS *cannot* be generated
  locally on Windows — it requires macOS — so CI is the way.
- **Locally** (Mac for iOS; Windows/Mac/Linux for Android via Git Bash/WSL) —
  §§ 1–4 below.

## CI (GitHub Actions — no Mac needed)

1. Seed the demo account (§2) against your backend.
2. Add these repository **secrets** (Settings → Secrets and variables → Actions):
   | Secret | For |
   |---|---|
   | `DEMO_EMAIL`, `DEMO_PASSWORD` | the seeded demo owner login |
   | `PLAY_STORE_SERVICE_ACCOUNT_JSON` | Play upload (you already have this) |
   | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key — create at App Store Connect → Users and Access → Integrations; `ASC_KEY_P8` is the **contents** of the `.p8` file |
3. Actions tab → **Store Screenshots** → **Run workflow**. Pick platforms
   (`both`/`ios`/`android`) and whether to upload (off = downloadable artifacts
   only). That's it — no local devices, works from Windows.

Everything below is the local/manual path and the reference for what the CI
does under the hood.

## 1. One-time setup

**Flutter side**
```bash
cd my_app
flutter pub get        # pulls in integration_test (added to dev_dependencies)
```

**fastlane** (for upload)
```bash
gem install fastlane
```

**Simulators / emulators** — edit the device lists at the top of
`tool/screenshots.sh` to match what you have installed:
- iOS: `xcrun simctl list devices`
- Android: `emulator -list-avds` (create AVDs in Android Studio if needed)

## 2. Seed the demo account (backend)

Run against the **same backend the app talks to** (production, since the app's
default `API_URL` is `https://paws4thoughtdogs.com`). Creates an owner with a
dog, a small gallery, and a couple of feed posts (uses generated placeholder
images — swap for real photos any time via the app):

```bash
python manage.py seed_demo_data \
  --email demo-owner@paws4thoughtdogs.com \
  --password 'Paws4Demo!2026' \
  --dog-name Luna
```

It prints the `DEMO_EMAIL` / `DEMO_PASSWORD` to use next. Re-running is safe
(idempotent). Tip: log in as this account in the app first and upload a few real
dog photos — they'll make far nicer screenshots than the placeholders.

## 3. Capture (one command, all devices)

```bash
cd my_app
export DEMO_EMAIL='demo-owner@paws4thoughtdogs.com'
export DEMO_PASSWORD='Paws4Demo!2026'

./tool/screenshots.sh          # iOS + Android
./tool/screenshots.sh ios      # iOS only (needs macOS)
./tool/screenshots.sh android  # Android only
```

Raw PNGs land in `build/screenshots/<device>/` and are copied into the fastlane
layout:
- iOS → `fastlane/screenshots/en-GB/` (deliver maps device by pixel size)
- Android → `fastlane/metadata/android/en-GB/images/{phone,sevenInch,tenInch}Screenshots/`

## 4. Upload

**Android** (uses your Play service-account JSON):
```bash
export SUPPLY_JSON_KEY=/path/to/play-service-account.json
cd my_app/fastlane && fastlane upload_android
```

**iOS** (needs an App Store Connect API key — create one in App Store Connect →
Users and Access → Integrations → App Store Connect API):
```bash
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
cd my_app/fastlane && fastlane upload_ios
```
Both lanes upload **screenshots only** (no binary/metadata changes), and target
the **alpha** track on Play.

## Device matrix

| Store | Device (sim/AVD) | Covers |
|---|---|---|
| App Store | iPhone 16 Pro Max | 6.9" (required; also covers smaller iPhones) |
| App Store | iPad Pro 13-inch (M4) | iPad 13" (only if you ship iPad) |
| Play Store | Pixel 7 (phone) | phone screenshots |
| Play Store | ~10" tablet AVD | tablet screenshots (optional) |

Apple now lets a single 6.9" iPhone set cover the smaller iPhone sizes, so one
iPhone sim is enough. Add more sims/AVDs to the arrays in `tool/screenshots.sh`
if you want additional sizes.

## Which screens are captured

Owner experience (`integration_test/screenshots_test.dart`), in store order:

1. `01_feed` — the daily photo feed (owners land here on launch)
2. `02_dog_profile` — the dog profile: photo, pickup/drop-off times, upcoming dates
3. `03_gallery` — the dog's photo gallery (the profile scrolled to the grid)
4. `04_booking` — the "Request Boarding" dialog
5. `05_profile` — the owner's profile + notification settings

Each capture is deterministic — the harness navigates to the screen and only
shoots once it's confirmed it's there, so a screenshot is never a stray or
half-loaded state. To add/reorder, edit that file — each capture is a
`binding.takeScreenshot('NN_name')` call. `fastlane/captions.strings` holds
optional store-listing copy keyed by the same names — it's not burned onto the
images (see the note at the top), just a handy place to keep the captions.

> The boarding **calendar** (`BoardingRequestListScreen`) is staff/deep-link
> only — there's no owner-facing navigation to it — so the owner booking story
> is told via the gallery + the Request Boarding dialog instead.

### Make them look like real dogs

The demo account's images come from `seed_demo_data`, which generates on-brand
gradient placeholders (paw motif + caption) when the account has no media yet.
They look intentional, but **real dog photos make far better store listings** —
log into the demo account in the app and upload a few; the seed command leaves
existing media untouched, so your uploads are what gets captured.

## Troubleshooting

- **`Demo login failed`** — check `DEMO_EMAIL`/`DEMO_PASSWORD` and that
  `seed_demo_data` ran against the backend the app points at.
- **A capture is blank / wrong screen** — the finders assume the current owner
  layout. Adjust the relevant step in `screenshots_test.dart` (e.g. the dog card
  or "Profile" menu finder).
- **iOS screenshots fail** — ensure the test calls
  `binding.convertFlutterSurfaceToImage()` before capturing (it does, guarded by
  `Platform.isIOS`); this requires a simulator, not a headless run.
- **`pumpAndSettle` timeouts** — we deliberately pump in real time
  (`_waitFor`) instead, to tolerate the offline banner / feed polling. Bump the
  `seconds:` values if a screen needs longer to load over the network.
- **iOS capture hangs on "Waiting for VM Service port"** — the
  simulator ↔ flutter handshake is intermittently flaky. CI caps each attempt
  with `gtimeout` and retries once; locally, just re-run `./tool/screenshots.sh
  ios`.
