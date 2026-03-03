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
FLUTTER_VERSION="3.41.2"

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
# Clean old pods to avoid stale cache issues, then install fresh.
echo "Running pod install..."
cd ios
rm -rf Pods
pod install --repo-update

echo "ci_post_clone.sh setup complete."
