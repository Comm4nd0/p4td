#!/usr/bin/env bash
#
# Capture App Store + Play Store screenshots by driving the real app, signed in
# as the demo owner account, across the required device sizes.
#
# Run from my_app/ on a Mac (iOS sims need macOS). Requires the demo creds:
#
#   export DEMO_EMAIL='demo-owner@paws4thoughtdogs.com'
#   export DEMO_PASSWORD='••••••••'
#   ./tool/screenshots.sh            # capture on all devices
#   ./tool/screenshots.sh ios        # iOS only
#   ./tool/screenshots.sh android    # Android only
#
# Raw PNGs land in build/screenshots/<device-key>/ and are then copied into the
# fastlane layout (fastlane/screenshots for iOS deliver, fastlane/metadata for
# Android supply). Run `fastlane frame` next to add device frames + captions,
# then `fastlane upload_ios` / `fastlane upload_android`.
#
# ── EDIT THESE to match the simulators/emulators you have installed ──────────
# iOS: simulator names (xcrun simctl list devices). One per required size.
IOS_DEVICES=(
  "iPhone 16 Pro Max"            # App Store 6.9" (required)
  "iPad Pro 13-inch (M4)"        # App Store iPad 13" (required if you ship iPad)
)
# Android: AVD names you created (emulator -list-avds). Phone + tablets.
ANDROID_AVDS=(
  "Pixel_7_API_34"               # phone
  "Nexus_9_API_34"               # ~10" tablet
)
# Locale folder used by fastlane (App Store + Play locale, e.g. en-GB).
LOCALE="en-GB"
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
cd "$(dirname "$0")/.."   # -> my_app/

if [[ -z "${DEMO_EMAIL:-}" || -z "${DEMO_PASSWORD:-}" ]]; then
  echo "ERROR: set DEMO_EMAIL and DEMO_PASSWORD env vars first." >&2
  exit 1
fi

WHAT="${1:-all}"
DRIVE=(flutter drive
  --driver=test_driver/integration_test.dart
  --target=integration_test/screenshots_test.dart
  --dart-define=DEMO_EMAIL="$DEMO_EMAIL"
  --dart-define=DEMO_PASSWORD="$DEMO_PASSWORD"
)

slugify() { echo "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-'; }

run_ios() {
  command -v xcrun >/dev/null || { echo "xcrun not found (need macOS/Xcode)"; exit 1; }
  for name in "${IOS_DEVICES[@]}"; do
    local key; key="ios-$(slugify "$name")"
    echo "▶  iOS: $name"
    xcrun simctl boot "$name" 2>/dev/null || true
    xcrun simctl bootstatus "$name" -b || true
    SCREENSHOT_OUT="build/screenshots/$key" \
      "${DRIVE[@]}" -d "$name"
    xcrun simctl shutdown "$name" 2>/dev/null || true
  done
}

run_android() {
  command -v emulator >/dev/null || { echo "android emulator not found"; exit 1; }
  for avd in "${ANDROID_AVDS[@]}"; do
    local key; key="android-$(slugify "$avd")"
    echo "▶  Android: $avd"
    emulator -avd "$avd" -no-snapshot -no-boot-anim -netdelay none -netspeed full >/dev/null 2>&1 &
    local pid=$!
    adb wait-for-device
    # wait for full boot
    until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do sleep 2; done
    SCREENSHOT_OUT="build/screenshots/$key" \
      "${DRIVE[@]}" -d emulator-5554
    adb -s emulator-5554 emu kill 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}

rm -rf build/screenshots
[[ "$WHAT" == "all" || "$WHAT" == "ios" ]] && run_ios
[[ "$WHAT" == "all" || "$WHAT" == "android" ]] && run_android

# ── Organise raw captures into the fastlane layout ───────────────────────────
echo "▶  Organising into fastlane layout…"
# iOS deliver: fastlane/screenshots/<locale>/  (deliver maps device by pixel size)
mkdir -p "fastlane/screenshots/$LOCALE"
for d in build/screenshots/ios-*; do
  [[ -d "$d" ]] || continue
  cp "$d"/*.png "fastlane/screenshots/$LOCALE/" 2>/dev/null || true
done

# Android supply: fastlane/metadata/android/<locale>/images/{phone,sevenInch,tenInch}Screenshots/
android_dir="fastlane/metadata/android/$LOCALE/images"
mkdir -p "$android_dir/phoneScreenshots" "$android_dir/sevenInchScreenshots" "$android_dir/tenInchScreenshots"
for d in build/screenshots/android-*; do
  [[ -d "$d" ]] || continue
  case "$d" in
    *tablet*|*nexus-9*|*10*|*pixel-tablet*) dest="$android_dir/tenInchScreenshots" ;;
    *seven*|*7in*)                          dest="$android_dir/sevenInchScreenshots" ;;
    *)                                       dest="$android_dir/phoneScreenshots" ;;
  esac
  cp "$d"/*.png "$dest/" 2>/dev/null || true
done

echo "✅  Raw screenshots captured."
echo "    Next: cd fastlane && fastlane frame   (frames + captions)"
echo "    Then: fastlane upload_ios  /  fastlane upload_android"
