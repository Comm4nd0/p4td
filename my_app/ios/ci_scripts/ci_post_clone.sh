#!/bin/sh

# Fail on any error
set -e
# Print commands for debugging
set -x

# FIX: Set locale to avoid Ruby/CocoaPods ASCII errors
export LANG=en_US.UTF-8

# Debugging
echo "Starting ci_post_clone.sh..."
echo "Current directory: $(pwd)"

# Install Flutter
# We install it to the repo root ensuring path consistency
FLUTTER_ROOT="$CI_PRIMARY_REPOSITORY_PATH/flutter"

if [ -d "$FLUTTER_ROOT" ]; then
    echo "Flutter already exists at $FLUTTER_ROOT"
else
    echo "Downloading Flutter to $FLUTTER_ROOT..."
    git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$FLUTTER_ROOT"
fi

export PATH="$PATH:$FLUTTER_ROOT/bin"

# Run flutter doctor to see what state we are in
echo "Checking Flutter environment..."
flutter doctor -v

# Navigate to the Flutter project directory
APP_DIR="$CI_PRIMARY_REPOSITORY_PATH/my_app"
echo "Navigating to App Directory: $APP_DIR"
cd "$APP_DIR"

# Get Flutter dependencies
echo "Running flutter pub get..."
flutter pub get

# FIX: Ensure iOS artifacts are downloaded
echo "Precaching iOS artifacts..."
flutter precache --ios

# FIX: Force FLUTTER_ROOT in Generated.xcconfig to match our manual install
# This ensures that when Xcode runs, it finds the Flutter we installed, not some other path.
GENERATED_XCCONFIG="$APP_DIR/ios/Flutter/Generated.xcconfig"
if [ -f "$GENERATED_XCCONFIG" ]; then
    echo "Forcing FLUTTER_ROOT in Generated.xcconfig..."
    # Remove existing FLUTTER_ROOT line
    sed -i '' '/FLUTTER_ROOT=/d' "$GENERATED_XCCONFIG"
    # Append our correct path
    echo "FLUTTER_ROOT=$FLUTTER_ROOT" >> "$GENERATED_XCCONFIG"
    echo "Updated generated config:"
    cat "$GENERATED_XCCONFIG"
fi

# Install CocoaPods
echo "Running pod install in ios/..."
cd ios
# Remove --repo-update to save memory/time. Using lockfile.
pod install

echo "ci_post_clone.sh completed successfully."
