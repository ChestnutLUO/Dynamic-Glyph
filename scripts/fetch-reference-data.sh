#!/bin/sh
# Fetches the third-party reference tables the test suite uses as an oracle.
#
# They are NOT redistributed with this repository: the upstream publishes no
# licence. See Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/PROVENANCE.md
# and satisfy yourself about the licence position before running this.
#
# CI never runs this. Only tests requiring these optional inputs skip without
# them. Full validation requires both files; see `make test-full`.
set -eu

UPSTREAM="https://github.com/chibatching/glyph-predictor-data"
REVISION="109f6c32d24c9f219e946a1423642390db6ce86b"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures"

printf 'This clones %s into a temporary directory and copies two CSV files into\n' "$UPSTREAM"
printf '%s\n\nContinue? [y/N] ' "$DEST"
read -r reply
case "$reply" in [yY]*) ;; *) echo "Cancelled."; exit 1 ;; esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' 0
trap 'exit 1' HUP INT TERM
git init --quiet "$WORK/data"
git -C "$WORK/data" fetch --depth 1 "$UPSTREAM" "$REVISION"
git -C "$WORK/data" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$WORK/data" rev-parse HEAD)" = "$REVISION"

# Validate BOTH files before replacing either local input. Hash raw bytes so
# that the LF/CRLF distinction exercised by the parser tests is preserved.
cat > "$WORK/data/checksums" <<'CHECKSUMS'
72c3e0f1b93992cf725bf2ce8adfdb2df4daddf6b5f8a6c8f7e8629e6934b6e7  glyph_line.csv
b1eaac450aa60643e25c17ae5c12ba8803dd0c50d60823dda5f6768ba9e2c5bf  glyph.csv
CHECKSUMS
(cd "$WORK/data" && shasum -a 256 -c checksums)

for f in glyph_line.csv glyph.csv; do
    cp "$WORK/data/$f" "$DEST/$f"
    echo "copied $f"
done

echo
echo "Done. Both files are gitignored, so they stay local to this checkout."
echo "Validated upstream revision: $REVISION"
echo "Run: make -C Packages/GlyphRecognition test-full"
