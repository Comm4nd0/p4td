#!/bin/sh
# Xcode Cloud runs this after xcodebuild. When the build is being distributed
# (TestFlight / App Store Connect), write the TestFlight "What to Test" notes
# from the commits this push brought in, so testers see what changed.
#
# Xcode Cloud picks the notes up from TestFlight/WhatToTest.<locale>.txt next
# to the workspace (my_app/ios/TestFlight), one file per locale.
#
# Best-effort: nothing here may fail the build — a missing note is better
# than a missing build.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NOTES_DIR="$SCRIPT_DIR/../TestFlight"

if [ -z "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]; then
  echo "Not a distributed build; skipping TestFlight notes."
  exit 0
fi

cd "${CI_PRIMARY_REPOSITORY_PATH:-$SCRIPT_DIR/../../..}" || exit 0

# Xcode Cloud clones shallow; deepen enough to see the push's commits.
git fetch --deepen 50 --quiet 2>/dev/null || true

VERSION=$(sed -n 's/^version: *//p' my_app/pubspec.yaml | head -n 1)
VERSION=${VERSION%%+*}  # Xcode Cloud stamps its own build number

# A push to main is a "Merge the X into main" commit: its notes are the app
# commits it merged. Anything else (a direct commit) is just that commit.
if git rev-parse --verify --quiet HEAD^2 >/dev/null; then
  RANGE="HEAD^1..HEAD"
else
  RANGE="HEAD~1..HEAD"
fi
CHANGES=$(git log --no-merges --format='• %s' "$RANGE" -- my_app 2>/dev/null)
if [ -z "$CHANGES" ]; then
  CHANGES=$(git log -1 --format='• %s' 2>/dev/null)
fi

mkdir -p "$NOTES_DIR" || exit 0

# TestFlight caps What to Test at 4000 characters.
{
  echo "Version ${VERSION:-unknown}"
  echo
  echo "What's changed:"
  echo "$CHANGES"
} | cut -c1-500 | head -c 3900 > "$NOTES_DIR/WhatToTest.en-GB.txt"
cp "$NOTES_DIR/WhatToTest.en-GB.txt" "$NOTES_DIR/WhatToTest.en-US.txt"

echo "TestFlight notes:"
cat "$NOTES_DIR/WhatToTest.en-GB.txt"
exit 0
