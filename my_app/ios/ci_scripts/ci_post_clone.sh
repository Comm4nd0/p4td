#!/bin/sh

# Fail on any error
set -e
# Detailed logs
set -x

# Fix Locale for CocoaPods/Ruby
export LANG=en_US.UTF-8

echo "Starting ci_post_clone.sh (Homebrew Approach)..."

# 1. Install Flutter via Homebrew
# This ensures a standard, system-wide installation path (stable).
# We disable auto-update to speed it up.
export HOMEBREW_NO_AUTO_UPDATE=1
echo "Installing Flutter via Homebrew..."
brew install --cask flutter

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
flutter config --no-analytics

# 4. Navigate to Project
APP_DIR="$CI_PRIMARY_REPOSITORY_PATH/my_app"
echo "Navigating to $APP_DIR"
cd "$APP_DIR"

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
