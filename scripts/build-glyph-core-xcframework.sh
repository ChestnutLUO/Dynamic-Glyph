#!/bin/sh
# Compiles the C++ recognition core (Packages/GlyphRecognition/Sources/
# GlyphCoreCxx) into a static-library xcframework at
# Packages/GlyphRecognition/Binaries/GlyphCore.xcframework, with slices for
# iOS devices, the iOS simulator and macOS.
#
# Package.swift switches GlyphCoreCxx to this binary when it exists, so the
# app and the package tests link the compiled framework instead of building
# the sources. Rerun this script after changing the core. `--remove` deletes
# the binary and goes back to the source target.
#
#   sh scripts/build-glyph-core-xcframework.sh            build (or rebuild)
#   sh scripts/build-glyph-core-xcframework.sh --remove   back to the sources
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/Packages/GlyphRecognition"
CORE="$PACKAGE/Sources/GlyphCoreCxx"
HEADERS="$CORE/include"
OUTPUT="$PACKAGE/Binaries/GlyphCore.xcframework"

# SwiftPM and Xcode cache a manifest's evaluation in a shared database keyed
# by the manifest's text, not by the files it looks at, so adding or removing
# Binaries/ is not seen until this package's entries are dropped. The cache
# rebuilds them on the next evaluation.
forget_cached_manifest() {
    cache="$HOME/Library/Caches/org.swift.swiftpm/manifests/manifest.db"
    [ -f "$cache" ] || return 0
    quoted="$(printf '%s/' "$PACKAGE" | sed "s/'/''/g")"
    if ! sqlite3 -cmd '.timeout 5000' "$cache" \
        "DELETE FROM MANIFEST_CACHE WHERE instr(value, '$quoted') > 0;" 2>/dev/null; then
        echo "warning: could not drop the cached manifest from $cache." >&2
        echo "  Run 'swift package purge-cache' once, or the next build may still" >&2
        echo "  use the previous choice of binary or source." >&2
    fi
}

case "${1:-}" in
    "") ;;
    --remove)
        rm -rf "$PACKAGE/Binaries"
        forget_cached_manifest
        echo "Removed $PACKAGE/Binaries; GlyphCoreCxx builds from source."
        exit 0
        ;;
    *)
        echo "usage: $0 [--remove]" >&2
        exit 2
        ;;
esac

# A failed build leaves no binary behind, so the package falls back to the
# sources rather than linking a stale one.
rm -rf "$OUTPUT"
forget_cached_manifest

# The package's platforms: iOS 16, macOS 13.
IOS_MIN=16.0
MACOS_MIN=13.0

WORK="$(mktemp -d -t glyph-core-xcframework)"
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM

if ! ls "$CORE"/*.cpp >/dev/null 2>&1; then
    echo "error: no .cpp sources in $CORE" >&2
    exit 1
fi
if [ ! -f "$HEADERS/glyph_core.h" ] || [ ! -f "$HEADERS/module.modulemap" ]; then
    echo "error: $HEADERS needs glyph_core.h and module.modulemap" >&2
    exit 1
fi

# compile_slice <sdk> <target triple> <output .a>
# Hidden visibility keeps the core's C++ internals out of the symbol table;
# the gc_* functions still link from the static archive because the linker
# resolves private-extern symbols between the objects of one link.
compile_slice() {
    sdk="$1"
    triple="$2"
    archive="$3"
    objects="$WORK/obj/$triple"
    mkdir -p "$objects"
    for source in "$CORE"/*.cpp; do
        object="$objects/$(basename "$source" .cpp).o"
        xcrun --sdk "$sdk" clang++ -target "$triple" \
            -std=c++17 -Os -fvisibility=hidden -DNDEBUG \
            -Wall -Werror=return-type \
            -I "$HEADERS" -I "$CORE" \
            -c "$source" -o "$object"
    done
    mkdir -p "$(dirname "$archive")"
    xcrun --sdk "$sdk" libtool -static -no_warning_for_no_symbols \
        -o "$archive" "$objects"/*.o
}

# fat_library <sdk> <output .a> <triple>...
fat_library() {
    sdk="$1"
    output="$2"
    shift 2
    for triple in "$@"; do
        compile_slice "$sdk" "$triple" "$WORK/thin/$sdk/$triple/libGlyphCore.a"
    done
    mkdir -p "$(dirname "$output")"
    xcrun lipo -create "$WORK/thin/$sdk"/*/libGlyphCore.a -output "$output"
}

fat_library iphoneos "$WORK/iphoneos/libGlyphCore.a" \
    "arm64-apple-ios$IOS_MIN"
fat_library iphonesimulator "$WORK/iphonesimulator/libGlyphCore.a" \
    "arm64-apple-ios$IOS_MIN-simulator" "x86_64-apple-ios$IOS_MIN-simulator"
fat_library macosx "$WORK/macosx/libGlyphCore.a" \
    "arm64-apple-macos$MACOS_MIN" "x86_64-apple-macos$MACOS_MIN"

mkdir -p "$(dirname "$OUTPUT")"
xcodebuild -create-xcframework \
    -library "$WORK/iphoneos/libGlyphCore.a" -headers "$HEADERS" \
    -library "$WORK/iphonesimulator/libGlyphCore.a" -headers "$HEADERS" \
    -library "$WORK/macosx/libGlyphCore.a" -headers "$HEADERS" \
    -output "$OUTPUT" >/dev/null
forget_cached_manifest

echo "Built $OUTPUT"
for library in "$OUTPUT"/*/libGlyphCore.a; do
    slice="$(basename "$(dirname "$library")")"
    echo "  $slice: $(xcrun lipo -archs "$library") ($(du -h "$library" | cut -f1 | tr -d ' '))"
done
echo "  total: $(du -sh "$OUTPUT" | cut -f1 | tr -d ' ')"
