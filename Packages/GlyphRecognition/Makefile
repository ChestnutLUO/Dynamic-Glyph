# macOS 27 stamps com.apple.provenance on files written by unsigned processes,
# and the swiftbuild codesign step rejects bundles carrying it ("resource fork,
# Finder information, or similar detritus not allowed"). The attribute is
# reapplied on every write, so one clear is not enough: the build completes and
# re-stamps, the clear then removes it, and the next run only has the signing
# step left to redo. Two passes is what it takes in practice; three is headroom.
.PHONY: test test-full
test:
	@for i in 1 2 3; do \
	  xattr -cr .build 2>/dev/null; \
	  if swift test; then exit 0; fi; \
	done; \
	echo "still failing -- try: swift test --build-system native"; exit 1

# Opt in to corpus validation; a missing input must fail, not silently skip.
test-full:
	@test -f Tests/GlyphRecognitionTests/Fixtures/glyph_line.csv && \
	  test -f Tests/GlyphRecognitionTests/Fixtures/glyph.csv || \
	  { echo "Missing reference tables; see Tests/GlyphRecognitionTests/Fixtures/PROVENANCE.md"; exit 1; }
	GLYPH_REQUIRE_REFERENCE_DATA=1 $(MAKE) test
