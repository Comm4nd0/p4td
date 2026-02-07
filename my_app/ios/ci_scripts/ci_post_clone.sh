#!/bin/sh

# Fail on any error
set -e
# Detailed logs
set -x

# Fix Locale for CocoaPods/Ruby
export LANG=en_US.UTF-8

echo "Starting ci_post_clone.sh (Homebrew Approach)..."

# 1. Install Flutter via Homebrew
# We disable auto-update to speed it up.
export HOMEBREW_NO_AUTO_UPDATE=1
echo "Installing Flutter via Homebrew..."
if brew list --cask flutter > /dev/null 2>&1; then
    echo "Flutter is already installed."
else
    brew install --cask flutter
fi

# 2. Add to PATH (Homebrew usually links it, but let's be safe)
# Try standard locations
if [ -f "/opt/homebrew/bin/flutter" ]; then
    export PATH="$PATH:/opt/homebrew/bin"
elif [ -f "/usr/local/bin/flutter" ]; then
    export PATH="$PATH:/usr/local/bin"
fi

# 3. Verify Flutter
echo "Checking Flutter version..."
flutter --version
flutter doctor -v
flutter config --no-analytics

# 4. Navigate to Project
APP_DIR="$CI_PRIMARY_REPOSITORY_PATH/my_app"
echo "Navigating to $APP_DIR"
cd "$APP_DIR"

# 3.5 Restore GoogleService-Info.plist (Critical for Firebase)
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

# 6. Precache iOS artifacts (critical for first run)
echo "Precaching iOS artifacts..."
flutter precache --ios

# 7. Install CocoaPods
echo "Running pod install..."
cd ios
# Clean slate
rm -rf Pods
rm -f Podfile.lock
pod install

echo "ci_post_clone.sh setup complete."
