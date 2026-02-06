#!/bin/sh

# Fail on any error
set -e

# FIX: Set locale to avoid Ruby/CocoaPods ASCII errors
export LANG=en_US.UTF-8

# Debugging
echo "Starting ci_post_clone.sh..."
echo "Current directory: $(pwd)"

# Install Flutter
if [ -d "$HOME/flutter" ]; then
    echo "Flutter already exists at $HOME/flutter"
else
    echo "Downloading Flutter..."
    git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
fi

export PATH="$PATH:$HOME/flutter/bin"

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

# Install CocoaPods
echo "Running pod install in ios/..."
cd ios
# Use repo-update to ensure specs are fresh
pod install --repo-update

echo "ci_post_clone.sh completed successfully."
