# Pixel recognition

The first implementation accepts upright luminance pixels and returns the
detected lattice, edge evidence, and candidate Glyphs. The core target imports
no image or capture frameworks. `GlyphRecognitionImages` handles Apple image
decoding, and `glyph-recognize` runs the pipeline on saved frames.

## Run on Spike B

From `Packages/GlyphRecognition`:

```sh
swift run --build-system native glyph-recognize \
  --glyphs Tests/GlyphRecognitionTests/Fixtures/glyph_line.csv \
  Tests/GlyphRecognitionTests/Fixtures/Assets/Screenshots/Frames/frame-02389.jpg \
  Tests/GlyphRecognitionTests/Fixtures/Assets/Screenshots/Frames/frame-02690.jpg
```

The command emits one JSON record per frame. A fresh fit finds eleven rings
in 2389 (RMS residual 0.245 pixels) and ten in 2690 (0.240 pixels). The cursor
obscures node 8 in the latter. Expected states:

| Frame | Meaning | Result |
| --- | --- | --- |
| 02389 | Empty array before presentation | `noStroke`, no candidates |
| 02690 | Player input with particles and an incomplete/off-array stroke | `unrecognizedStroke`, no candidates |
| 02092 | Map view with roads and particles | `calibrationUnavailable` |

Neither hacking example contains a complete labeled presented Glyph. They are
calibration and rejection fixtures, not positive recognition examples.

The command above attempts calibration independently on every frame and is
primarily a geometry diagnostic. Most drawn-over arrays cannot be calibrated.
For recognition, acquire calibration on an empty array and explicitly reuse it
at the same layout, orientation, and resolution:

```sh
swift run --build-system native glyph-recognize \
  --glyphs Tests/GlyphRecognitionTests/Fixtures/glyph_line.csv \
  --calibration Tests/GlyphRecognitionTests/Fixtures/Assets/Screenshots/Frames/frame-02389.jpg \
  Tests/GlyphRecognitionTests/Fixtures/Assets/Screenshots/Frames/frame-02690.jpg
```

Reference CSVs remain runtime inputs. Their provenance and distribution limits
are documented in `Tests/GlyphRecognitionTests/Fixtures/PROVENANCE.md`.

## Algorithm

1. Threshold luminance at 160 and flood-fill bright connected components.
   Keep approximately round, hollow components at a size relative to the frame.
2. Fit apex/base/outer-ring hypotheses to the canonical lattice. Require at
   least eight matching rings, then refine x/y scale and translation by least
   squares. The initial detector needs both apex and base visible.
3. Sample each possible elementary edge in 24 spatial bins, excluding node
   rings and glow. Compare the center strip to parallel background strips;
   a bin needs luminance at least 60 and contrast support at least 0.18.
   At least 20 of 24 bins must pass. This deliberately tolerates four missing
   bins, including a contiguous gap; it does not prove a line is connected.
   The tolerance is pinned by tests but is not calibrated against real trails.
4. Split template edges at intervening lattice nodes. This makes a long line
   equivalent to the adjacent segments that produce the same pixels, including
   the backtracking `imperfect` case.
5. Compare undirected edge sets. Return every template within two edge changes,
   sorted by distance and name. Same-shape aliases remain visible. Empty edge
   evidence never produces a nearest-neighbor guess.

`uniqueVisibleShape` and `hasUniqueVisibleShape` describe the current visible
geometry, never completion. `extensions` lists every template strictly
containing those edges, even beyond the nearest-match distance limit. For
example, `03` matches `see` but may become `advance`. Even an empty extensions
list does not establish a presentation boundary or table completeness.

Bright pixels outside the node masks are also checked spatially against the
detected segments. More than 35% unexplained pixels (with a 24-pixel allowance)
downgrades a geometric match to `unexplainedInk`. `exactMatches` remains
available for diagnosis in that state; it must not be used as acceptance.
This check depends on the current luminance/width thresholds and cannot detect
a union of two Glyphs that is itself a valid template. Distances and contrast
values are not calibrated probabilities.

`observe(_:calibration:)` requires a fit. `calibrateAndObserve(_:)` is a separate
bootstrap operation: `calibrationUnavailable` means an array was not located,
which includes obscured rings on a valid Glyph screen. It must not reset a hack
as if the screen had changed. `calibrationMismatch` explicitly reports wrong
frame dimensions; the CLI treats it as an error.

## Multiple frames and prediction

`GlyphStrokeAccumulator` takes the maximum support for each spatial bin across
frames. This can recover an edge from a moving/fading stroke even when no one
frame contains that entire edge. Its initializer requires a fixed calibration
and recognizer, and `append(_:)` samples images using those values. There is no
exact-Double comparison between independent per-frame fits.

`finish(completion:)` consumes the drawing and returns `GlyphStrokeResult`,
including frame count, per-frame states, edge sets, exact matches and extensions.
It defaults to `.unconfirmed`: `acceptedGlyph` is then always nil. Only an
explicit `.presentationBoundary` assertion from the caller can enable acceptance.
This allows a completed short Glyph such as `see` even when extensions exist.
The CLI only reports unconfirmed observations.

Exact per-frame shapes whose edge sets are not nested flag
`possibleBoundaryCrossing`; acceptance is refused even with an asserted final
boundary. Thus `clear` followed by `all` may geometrically resemble `clear_all`,
but is flagged for review. A legitimate fading compound can produce the same
history; this is conservative abstention, not a boundary detector. Other missed
boundaries remain possible. Provenance cannot replace external timing/phase
evidence.

`reset()` abandons a drawing. Resizing or exceeding the default 300-frame limit
throws and clears the drawing rather than preserving an incomplete prefix.

The caller must supply the boundary of ONE presented Glyph. Do not accumulate
all frames of a hack, and do not deduplicate consecutive equal Glyphs. Only
after a confirmed presentation boundary should an accepted recognition be
appended to `SequencePredictor`'s observed prefix. Preserve candidates or defer
when recognition is ambiguous; do not select the first near match as certain.

Spike B now connects capture buffers to provisional recognition using
`GlyphFrameSession` and a serial worker sampling at up to 20 Hz. The session
acquires calibration on an empty 11-ring array, reuses it during drawing, and
expires it after interruptions or eight seconds without a verified empty array.
The app saves per-frame JSON and transition screenshots; see the
[iPhone field-test instructions](../../Docs/FIELD_TESTING.md).

Automatic game-phase detection, Glyph boundary detection, Dynamic Island
output, and uncertainty-aware sequence inference are not implemented.
In particular, frame 2690 is player input and must not extend a presentation
prefix. Sparse screenshots saved five seconds apart cannot establish these
boundaries. A subsequent recording provides the first real positive examples.

## Recorded presentation

The user-provided 2026-09-17 screen recording contains the sequence
`see → truth → see → future → begin`. With calibration acquired before the
presentation, all 28 visible samples and 12 blank samples in the manually
annotated presentation interval pass at 20 Hz, resized to 603 x 1311. Each
visible sample contains the complete expected edge set; accumulation is not
needed for these five presentations. This is evidence for this clip, not a
universal claim about trail behavior.

See [the replay report](../../Tools/RecordingResults/2026-09-17/README.md) for
the time windows, contact sheets, limitations, and reproduction command.
`RecordingRecognitionTests` also runs the five representative positive frames
through the core and the sequence predictor, preserving the repeated `see`.

## Validation and limits

`FrameRecognitionTests` covers the three real frames, known hand-specified
pixel shapes, scale/translation, faint strokes with noise, all 142 reference
shapes rasterized through a segment renderer, partial exact matches and
extensions, disjoint temporal unions, stray ink, calibration failure under
strokes, gap/brightness/distance thresholds, same-shape aliases, malformed and
truncated images, calibration changes, bounded history and temporal reset.

The renderer is independent of the sampling algorithm but intentionally uses
the same canonical node geometry. Its vocabulary sweep is not independent
evidence for node labeling. Hand-specified asymmetric pixels constrain that
contract. The recording annotations use visible geometry and reference shapes,
not game-displayed names, so they do not provide an independent semantic-label
oracle for the whole vocabulary.

The synthetic vocabulary sweep establishes implementation behavior; one real
recording adds limited positive coverage, not a general accuracy estimate.
Thresholds are initial values for the dark
Spike B screen; rotation, perspective, substantial clutter and different game
themes require further validation. No on-device throughput claim is made.
Calibration must be invalidated when the screen layout changes; matching image
dimensions alone does not establish that a cached fit is still valid. ImageIO
must report complete image data; alpha composites over black. The valid final
pixel column is width - 1, so the detector's strict upper bound is intentional.

Run `make test`. If this macOS environment still rejects signing after the
Makefile retries, run `swift test --build-system native`.
