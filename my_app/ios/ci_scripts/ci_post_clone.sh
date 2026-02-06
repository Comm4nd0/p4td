#!/bin/sh

# Fail on any error
set -e

# Debugging
echo "Starting ci_post_clone.sh..."
echo "Current directory: $(pwd)"

# Install Flutter
# We install it to $HOME because we don't want to pollute the source tree
echo "Downloading Flutter..."
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# Run flutter doctor to see what state we are in (optional but helpful for debug logs)
flutter doctor -v

# Navigate to the Flutter project directory
# $CI_PRIMARY_REPOSITORY_PATH is the root of the git repo
# Our flutter project is in the 'my_app' subdirectory
APP_DIR="$CI_PRIMARY_REPOSITORY_PATH/my_app"
echo "Navigating to App Directory: $APP_DIR"
cd "$APP_DIR"

# Get Flutter dependencies
echo "Running flutter pub get..."
flutter pub get

# Install CocoaPods
# Note: Xcode Cloud environments usually have CocoaPods installed, but we run pod install
# to generate the Pods project and workspace integration that is ignored in git.
echo "Running pod install in ios/..."
cd ios
pod install

echo "ci_post_clone.sh completed successfully."
