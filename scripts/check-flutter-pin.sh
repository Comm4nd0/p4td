#!/usr/bin/env bash
#
# Every build surface must install the one Flutter version named in
# my_app/.flutter-version. This fails the build if any of them drifts off it.
#
# The drift this exists to stop has bitten twice. The GitHub Actions workflows
# all installed `channel: stable`, so the version moved on its own whenever
# Flutter shipped — that is what broke the Android release build when stable
# became 3.47 and Gradle 8.11.1 was suddenly too old. Meanwhile Xcode Cloud
# hardcoded its own version and nobody remembered to touch it, so iOS quietly
# sat six minor versions behind on 3.41.2. Neither showed up until a release
# failed.
#
# Run locally with: ./scripts/check-flutter-pin.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pin_file='my_app/.flutter-version'
workflow_dir='.github/workflows'
xcode_script='my_app/ios/ci_scripts/ci_post_clone.sh'

fail() { echo "ERROR: $*" >&2; failures=$((failures + 1)); }
failures=0

# --- 1. The pin itself is present and is an exact version ---
if [ ! -f "$pin_file" ]; then
    echo "ERROR: $pin_file is missing. It is the single source of truth for the Flutter version." >&2
    exit 1
fi

pin="$(tr -d '[:space:]' < "$pin_file")"
if ! printf '%s' "$pin" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "$pin_file must hold one exact version like 3.47.0, not '$pin'. A channel or a range is not reproducible."
fi

# Search the workflows for real configuration, ignoring comment lines. Without
# this, the comments in those files explaining the rule trip the rule.
scan() { grep -rn "$1" "$workflow_dir" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true; }
count() { scan "$1" | grep -c '' || true; }

# --- 2. No workflow installs a floating channel ---
# `channel: stable` resolves to whatever Flutter shipped most recently, so the
# same commit builds against a different SDK tomorrow.
hits="$(scan 'channel:[[:space:]]*\(stable\|beta\|master\|main\)')"
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    fail "the workflow(s) above install a floating Flutter channel. Use flutter-version from $pin_file instead."
fi

# --- 3. No workflow hardcodes a version ---
# Only a \${{ ... }} expression is allowed, so the value can come from the pin.
hits="$(scan 'flutter-version:[[:space:]]*[^$[:space:]]')"
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    fail "the workflow(s) above hardcode a Flutter version. Read it from $pin_file instead."
fi

# --- 4. Every flutter-action call is paired with a version ---
# A bare `subosito/flutter-action@v2` with no `with:` block silently defaults
# to the latest stable — the same floating problem, harder to spot.
action_uses="$(count 'subosito/flutter-action')"
version_refs="$(count 'flutter-version:')"
if [ "$action_uses" -ne "$version_refs" ]; then
    fail "found $action_uses flutter-action step(s) but $version_refs flutter-version line(s) in $workflow_dir — every install must name the pinned version."
fi

# --- 5. Xcode Cloud reads the pin rather than carrying its own ---
if [ ! -f "$xcode_script" ]; then
    fail "$xcode_script is missing."
elif grep -nE '^[[:space:]]*FLUTTER_VERSION=["'"'"']?[0-9]' "$xcode_script" >&2; then
    fail "$xcode_script hardcodes FLUTTER_VERSION (line above). It must read $pin_file."
elif ! grep -q '\.flutter-version' "$xcode_script"; then
    fail "$xcode_script does not read $pin_file, so iOS can drift away from every other surface."
fi

if [ "$failures" -gt 0 ]; then
    echo >&2
    echo "$failures Flutter pin problem(s). All build surfaces must install the version in $pin_file." >&2
    exit 1
fi

echo "Flutter pin OK: every build surface installs $pin (from $pin_file)."
