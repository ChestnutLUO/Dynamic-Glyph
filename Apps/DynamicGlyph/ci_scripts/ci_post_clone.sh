#!/bin/sh
# Xcode Cloud runs this after checkout, before it resolves or builds anything.
# It only looks for ci_scripts beside the project or workspace the workflow
# builds, which is why this lives in Apps/DynamicGlyph and not at the root.
#
# The .xcodeproj is generated from project.yml and is not committed, so it does
# not exist yet at this point -- this script is what creates it.
set -eu

brew install xcodegen

# The run's build number, which is the only thing that keeps successive uploads
# distinct in App Store Connect. Config/Build.xcconfig includes this file
# optionally and last, so it overrides the "not a release" defaults in
# project.yml for the app and the widget extension together.
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
    echo "DG_BUILD_NUMBER = $CI_BUILD_NUMBER" > "$CI_PRIMARY_REPOSITORY_PATH/Config/CI.xcconfig"
fi

cd "$CI_PRIMARY_REPOSITORY_PATH/Apps/DynamicGlyph"
xcodegen generate
