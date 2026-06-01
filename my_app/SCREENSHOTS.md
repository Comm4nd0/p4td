# Store screenshots — automated

Generate App Store **and** Play Store screenshots from one Flutter integration
test, framed with captions, and upload them — no manual capturing on each device.

How it works: the test signs in as a **demo owner account** on the real backend
and walks the key owner screens, taking a screenshot at each. A script runs that
test across the required device sizes; fastlane then frames + captions + uploads.

```
seed demo data ──► capture (per device) ──► frame + caption ──► upload
 (Django cmd)        tool/screenshots.sh      fastlane frame      fastlane upload_*
```

## 1. One-time setup

**Flutter side**
```bash
cd my_app
flutter pub get        # pulls in integration_test (added to dev_dependencies)
```

**fastlane** (for framing + upload)
```bash
gem install fastlane
# Device frames for `frameit` (Apple + Google bezels):
cd my_app/fastlane && fastlane frameit download_frames
# Put a TTF at my_app/fastlane/fonts/Nunito-Bold.ttf (matches the app font),
# or edit Framefile.json to point at any font you have.
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

## 4. Frame + caption

```bash
cd my_app/fastlane
fastlane frame
```
Captions live in `fastlane/captions.strings` (keyed by screenshot name). Framed
files are written alongside the originals ending in `_framed.png`.

## 5. Upload

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

Owner experience (`integration_test/screenshots_test.dart`): **My Dogs → Dog
profile → Feed → Profile**. To add/reorder, edit that file — each capture is a
`binding.takeScreenshot('NN_name')` call; add a matching caption in
`fastlane/captions.strings`.

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
- **fastlane `frame` does nothing** — run `fastlane frameit download_frames`
  first and make sure the font path in `Framefile.json` exists.
