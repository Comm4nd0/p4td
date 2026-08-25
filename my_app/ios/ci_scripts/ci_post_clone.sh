#!/bin/sh

# Fail on any error
set -e
# Detailed logs
set -x

# Fix Locale for CocoaPods/Ruby
export LANG=en_US.UTF-8

# ---- Flutter version ----
# Read from my_app/.flutter-version, the single source of truth every build
# surface shares (the GitHub Actions workflows read the same file). Hardcoding
# it here is what let iOS sit on 3.41.2 while CI floated on to 3.47 — see
# CLAUDE.md > Flutter version pin. Change the version there, not here.
PIN_FILE="$CI_PRIMARY_REPOSITORY_PATH/my_app/.flutter-version"
if [ ! -f "$PIN_FILE" ]; then
    echo "ERROR: $PIN_FILE is missing — cannot determine which Flutter to install."
    exit 1
fi
FLUTTER_VERSION="$(tr -d '[:space:]' < "$PIN_FILE")"
if [ -z "$FLUTTER_VERSION" ]; then
    echo "ERROR: $PIN_FILE is empty."
    exit 1
fi

# 1. Install Flutter via Git (with retry for network issues)
echo "Installing Flutter $FLUTTER_VERSION..."
MAX_RETRIES=4
RETRY_DELAY=2
for i in $(seq 1 $MAX_RETRIES); do
    if git clone https://github.com/flutter/flutter.git --depth 1 -b "$FLUTTER_VERSION" "$HOME/flutter"; then
        echo "Flutter cloned successfully."
        break
    else
        if [ "$i" -eq "$MAX_RETRIES" ]; then
            echo "ERROR: Failed to clone Flutter after $MAX_RETRIES attempts."
            exit 1
        fi
        echo "Clone attempt $i failed, retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
        RETRY_DELAY=$((RETRY_DELAY * 2))
        rm -rf "$HOME/flutter"
    fi
done
export PATH="$HOME/flutter/bin:$PATH"

# 2. Verify the installed Flutter is the pinned one
echo "Flutter version:"
flutter --version
installed="$(flutter --version | sed -n 's/^Flutter \([0-9][0-9.]*\).*/\1/p' | head -1)"
if [ "$installed" != "$FLUTTER_VERSION" ]; then
    echo "ERROR: installed Flutter $installed does not match the pin $FLUTTER_VERSION."
    exit 1
fi

# 3. Navigate to Project
APP_DIR="$CI_PRIMARY_REPOSITORY_PATH/my_app"
echo "Navigating to $APP_DIR"
cd "$APP_DIR"

# 4. Restore GoogleService-Info.plist (Critical for Firebase)
# Since we removed this file from git (security), we must restore it from a CI secret.
# In Xcode Cloud, add an environment variable named 'GOOGLE_SERVICE_INFO_PLIST_BASE64'
# containing the base64 encoded content of the file.
if [ -n "$GOOGLE_SERVICE_INFO_PLIST_BASE64" ]; then
    echo "Restoring GoogleService-Info.plist from environment variable..."
    echo "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | base64 --decode > ios/Runner/GoogleService-Info.plist
else
    echo "WARNING: GOOGLE_SERVICE_INFO_PLIST_BASE64 not set. Build may fail if this file is missing."
fi

# 5. Force CocoaPods for plugin delivery
# Flutter can vend iOS plugins through Swift Package Manager instead of
# CocoaPods. That wiring is added to the Xcode project by `flutter build ios`
# — which never runs here: Xcode Cloud calls xcodebuild against
# Runner.xcworkspace directly, and this script only prepares the pods. So an
# SPM-vended plugin ends up imported by GeneratedPluginRegistrant.m but built
# by nothing, which is the "Module 'camera_avfoundation' not found" failure
# that appeared the moment iOS moved from Flutter 3.41.2 to 3.47.0.
# Keep every plugin on the CocoaPods path the Podfile and workspace expect.
echo "Disabling Swift Package Manager so all plugins resolve through CocoaPods..."
flutter config --no-enable-swift-package-manager \
    || echo "WARNING: could not disable Swift Package Manager on this Flutter version."

# 6. Build Flutter Dependencies
# This generates ios/Flutter/Generated.xcconfig with the correct FLUTTER_ROOT,
# and ios/Runner/GeneratedPluginRegistrant.m listing the plugins to import.
echo "Running flutter pub get..."
flutter pub get

# 7. Precache iOS artifacts
echo "Precaching iOS artifacts..."
flutter precache --ios

# 8. Install CocoaPods
# Clean old pods to avoid stale cache issues, then install fresh.
echo "Running pod install..."
cd ios
rm -rf Pods
pod install --repo-update

# 9. Every plugin the registrant imports must actually have been installed
# The registrant is generated from the resolved plugin list; Podfile.lock is
# what the build will really compile. When they disagree the failure surfaces
# as an opaque "Module 'x' not found" deep in the Xcode log, so say it here
# instead, naming the plugin and the file that expects it.
registrant="Runner/GeneratedPluginRegistrant.m"   # cwd is my_app/ios
if [ -f "$registrant" ] && [ -f Podfile.lock ]; then
    missing=""
    for module in $(sed -n 's/^@import \([A-Za-z0-9_]*\);.*/\1/p' "$registrant" | sort -u); do
        grep -q "[ -]$module " Podfile.lock || missing="$missing $module"
    done
    if [ -n "$missing" ]; then
        echo "ERROR: GeneratedPluginRegistrant.m imports plugin(s) CocoaPods did not install:$missing"
        echo "The Xcode build would fail with \"Module '...' not found\"."
        echo "Usually means the plugin resolved via Swift Package Manager instead of CocoaPods."
        exit 1
    fi
    echo "All plugins imported by the registrant are present in Podfile.lock."
else
    echo "WARNING: could not cross-check the registrant against Podfile.lock."
fi

echo "ci_post_clone.sh setup complete."
