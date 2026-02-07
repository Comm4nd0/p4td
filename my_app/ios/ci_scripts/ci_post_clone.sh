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

# FIX: Force FLUTTER_ROOT and FLUTTER_APPLICATION_PATH in Generated.xcconfig
# This ensures that when Xcode runs, it finds the Flutter we installed, not some other path.
GENERATED_XCCONFIG="$APP_DIR/ios/Flutter/Generated.xcconfig"
EXPORT_ENV_SH="$APP_DIR/ios/Flutter/flutter_export_environment.sh"

patch_config() {
    local file=$1
    if [ -f "$file" ]; then
        echo "Patching $file..."
        # Remove existing definitions
        sed -i '' '/FLUTTER_ROOT=/d' "$file"
        sed -i '' '/FLUTTER_APPLICATION_PATH=/d' "$file"
        
        # Append correct paths
        echo "FLUTTER_ROOT=$FLUTTER_ROOT" >> "$file"
        echo "FLUTTER_APPLICATION_PATH=$APP_DIR" >> "$file"
        
        echo "Updated $file content:"
        cat "$file"
    else
        echo "Warning: $file not found!"
    fi
}

patch_config "$GENERATED_XCCONFIG"
patch_config "$EXPORT_ENV_SH"

# Ensure xcode_backend.sh is executable
chmod +x "$FLUTTER_ROOT/packages/flutter_tools/bin/xcode_backend.sh"

# Install CocoaPods
echo "Running pod install in ios/..."
cd ios
# Delete Podfile.lock and Pods to force a fresh resolve matching this environment
rm -rf Pods
rm -f Podfile.lock
pod install

echo "ci_post_clone.sh completed successfully."
