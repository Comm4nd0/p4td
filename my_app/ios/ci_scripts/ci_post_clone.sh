#!/bin/sh

# Fail on any error
set -e
# Detailed logs
set -x

# Fix Locale for CocoaPods/Ruby
export LANG=en_US.UTF-8

# ---- Flutter version ----
# Pin to a specific stable tag so builds are reproducible.
# Update this when you upgrade Flutter locally.
FLUTTER_VERSION="3.38.4"

# 1. Install Flutter via Git
echo "Installing Flutter $FLUTTER_VERSION..."
git clone https://github.com/flutter/flutter.git --depth 1 -b "$FLUTTER_VERSION" "$HOME/flutter"
export PATH="$HOME/flutter/bin:$PATH"

# 2. Verify
echo "Flutter version:"
flutter --version

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

# 5. Build Flutter Dependencies
# This generates ios/Flutter/Generated.xcconfig with the correct FLUTTER_ROOT
echo "Running flutter pub get..."
flutter pub get

# 6. Precache iOS artifacts
echo "Precaching iOS artifacts..."
flutter precache --ios

# 7. Install CocoaPods
# Use the committed Podfile.lock so pod versions are reproducible.
echo "Running pod install..."
cd ios
pod install

echo "ci_post_clone.sh setup complete."
