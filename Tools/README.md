# Tools

## App tests

The snapshot limiter and the debug screen recorder used to be checked here by
hand-compiled `swiftc` harnesses. They are now the `DynamicGlyphTests` target,
run by ⌘U on the `DynamicGlyph` scheme with an iOS 27 simulator selected. That
is the scheme's test action, so CI runs the same thing. See the [recorder notes](#debug-screen-recorder) below for what
those tests pin down.

## `detect-nodes.swift`

Finds the eleven Glyph array nodes in a captured frame and prints their
centroids, normalised. This is how `NodeArray.canonical` was derived.

```sh
swift Tools/detect-nodes.swift <frame.jpg> [threshold=160]
```

The nodes are **rings, not discs** — bright annulus, dark centre — which is why
a naive "filled blob" filter finds none of them. Their signature in a 603×1311
capture is unmistakable and very tight:

| property | value |
|---|---|
| bounding box | ≈ 26 px square |
| fill ratio | ≈ 0.32 (the hole) |
| aspect | 1.00 |
| pixel count | 212–220 |

Everything else on screen — status bar text, the sequence hexagons, the buttons
— fails at least one of those. Scale the pixel counts with capture resolution;
fill and aspect are resolution independent.

## `check-recording.py`

Replays the manually annotated presentation in the user-provided
`ScreenRecording_09-17-2026 23-56-50_1.MP4`. Requires Python 3.11+, ffmpeg and a
release build of `glyph-recognize`. It extracts 200 samples from seconds 20-30,
uses a fixed empty-array calibration, and checks the 28 visible and 12 blank
presentation samples against explicit annotations. It does not detect phases
or boundaries automatically.

```sh
swift build --package-path Packages/GlyphRecognition --build-system native -c release --product glyph-recognize
python3 Tools/check-recording.py 'ScreenRecording_09-17-2026 23-56-50_1.MP4' \
  --output Tools/RecordingResults/2026-09-17
```

The output contains the source hash, a summary, every frame's recognition
result, and two contact sheets. Add `--save-fixtures` to regenerate the compact
PNG regression fixtures. See [the results](RecordingResults/2026-09-17/README.md).

## `check-phase-replay.py`

Replays a recording through the *whole* live pipeline — shape recognition, the
slot-indicator reader, Vision header text recognition and the presentation
tracker — and compares the recovered sequence against the manual annotation.
Unlike `check-recording.py`, nothing is annotated into the pipeline: the phase
comes from the header text and the boundaries from the indicator strip.

```sh
swift build --package-path Packages/GlyphRecognition --build-system native \
  -c release --product glyph-replay
python3 Tools/check-phase-replay.py 'ScreenRecording_09-17-2026 23-56-50_1.MP4' \
  --output Tools/PhaseReplayResults/2026-09-18
```

Exits nonzero if the recovered sequence or the slot count disagrees with the
annotation. See [the results](PhaseReplayResults/2026-09-18/README.md).

## `check-input-validation.py`

Runs the player-input validator alongside the presentation tracker at 20 fps,
scaled to 562 pixels wide. The default annotation is the all-correct five-Glyph
hack in `IMG_2003.MP4`. The replay fails on a `differs` verdict, a wrong recovered
sequence/count, or no input checks at all. It writes boundary events, per-frame
edge support, per-attempt verdicts and unavailable-reason counts as JSON.

```sh
swift build --package-path Packages/GlyphRecognition --build-system native \
  -c release --product glyph-replay
python3 Tools/check-input-validation.py IMG_2003.MP4 \
  --output /tmp/dynamicglyph-input-validation.json
```

Annotations are compared against results; they are never fed into recognition.
The last slot receives no verdict. This correct-drawing baseline cannot measure
missed deliberate errors or Redo behavior. See the
[input validation spec](../Docs/INPUT_VALIDATION.md).

## `check-ablations.py`

Replays every annotated recording through `glyph-replay` once as it is and
once for each component switched off: header text, slot strip, countdown bar,
layout check, calibration cache, ink check, the stability, slot-count-vote,
indicator-presentation and last-slot-release rules, and thinner sampling. Each
run is scored against a manual annotation of what the screen showed. The
switches are `glyph-replay --ablate`, and they exist only in the replay. The
two tracker rules that could not be switched off from outside are
`PresentationTracker.Policy` flags that default to on.

```sh
swift build --package-path Packages/GlyphRecognition --build-system native \
  -c release --product glyph-replay
python3 Tools/check-ablations.py --output Tools/AblationResults/2026-09-22/recheck
```

Needs the raw recordings named in the annotation, which are gitignored device
evidence. See [the results](AblationResults/2026-09-22/README.md).

## Debug screen recorder

`DynamicGlyphTests` drives the app's real debug screen recorder with synthetic
4:2:0 frames. The recorder imports no ScreenCaptureKit and no UIKit precisely so
that this is possible: the test target compiles its source directly, because the
app as a whole cannot be built for a simulator. Its fault-injection hooks
(`DEBUG_RECORDING_TESTING`) are compiled into the test bundle only.

It checks the admission boundaries (frame-rate cap and its floating-point
epsilon, non-`complete` frames, duplicate and backwards timestamps, and each of
the duration, byte and free-space caps), then records a real second of video and
asserts that the movie is playable, that its duration matches the receipt, that
the session anchor survives a non-zero timeline origin, and that finishing twice
is harmless. Frames are offered on a fixed 20 Hz schedule without waiting for
the encoder between frames. Separate fault tests stop with queued frames, stop
before writer setup, cancel the writer, force setup failure, wedge the encoder
past its deadline, and reach the wall-time cap with no frames or only idle frames.
Fault hooks are excluded from the app build.

`recording.json` distinguishes `finished`, `notStarted`, `failed`, and `timedOut`.
`stopReason` preserves the original reason even if finalization fails;
`framesDroppedFinalization` counts accepted frames lost to failure or timeout.
The duration cap bounds wall time from recorder creation as well as source time;
`durationSeconds` still describes the source timeline covered by the video.
A late encoder callback cannot overwrite a terminal receipt.

`recognition.jsonl` includes `recordingOfferMilliseconds` and
`callbackGapMilliseconds` (wall time between delivered screen callbacks, before
sampling). `processingMilliseconds` now starts at callback entry, so it includes
telemetry and recorder admission/copy as well as recognition. It ends before JSON
serialization and delivery. Writer setup and encoding run on the encoder queue;
these timings do not measure encoding latency or prove on-device performance.
