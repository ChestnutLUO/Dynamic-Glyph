#!/bin/sh
# Builds the app and its widget for iOS 18 without signing, to prove that
# every API newer than iOS 18 sits behind an availability check.
#
# The shipping deployment target stays at iOS 27 until capture on iOS 18-26 is
# proven on a device; this only overrides it for one build. It does not make
# the app capture on iOS 18: without ScreenCaptureKit there is no backend yet,
# and Start says so.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM

cd "$ROOT/Apps/DynamicGlyph"
xcodegen generate --quiet
xcodebuild build -quiet \
    -project DynamicGlyph.xcodeproj -scheme DynamicGlyph -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$WORK" \
    IPHONEOS_DEPLOYMENT_TARGET=18.0 CODE_SIGNING_ALLOWED=NO
echo "iOS 18 build succeeded."
