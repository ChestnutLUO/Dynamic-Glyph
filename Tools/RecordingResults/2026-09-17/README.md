# Recording validation: 2026-09-17

Source: `ScreenRecording_09-17-2026 23-56-50_1.MP4` in the repository root.
The source SHA-256 and machine-readable results are in [summary.json](summary.json)
and [frames.jsonl](frames.jsonl).

The video is approximately 39.865 seconds long, 1206 x 2622, variable frame rate.
This replay checks the 20-30 second interval at **20 samples/second**, resized
to the 603 x 1311 resolution used by Spike B. All 200 samples were analyzed with
one empty-array calibration from sample 25.150 seconds.

## Results

The five presentation slots were inspected visually. Their geometry is:

| Slot | Visible samples (seconds) | Expected Glyph | Correct samples | Unexplained bright ink |
| --- | --- | --- | --- | --- |
| 1 | 25.450-25.650 | see | 5/5 | 7.7-9.3% |
| 2 | 25.800-26.050 | truth | 6/6 | 10.2-12.4% |
| 3 | 26.200-26.450 | see | 6/6 | 8.2-11.1% |
| 4 | 26.600-26.800 | future | 5/5 | 9.5-12.3% |
| 5 | 26.950-27.200 | begin | 6/6 | 6.1-8.9% |

**28/28 labeled visible frames matched the expected name and exact edge set.**
The 12 blank samples in the 25.300-27.300 second presentation interval all
returned `noStroke`, without candidates. There were no classification failures
against these annotations. Sample times are on a 50 ms grid, not exact source
frame timestamps or game-event measurements.

`Tools/check-recording.py` also writes two contact sheets of the game's
frames, left-to-right then top-to-bottom, with 50 ms between cells
(`presentation-25300-26250.jpg` and `presentation-26300-27250.jpg`). They are
frames of the game's screen, so they are kept in the private test-assets
repository (`Tools/RecordingResults/2026-09-17/` there), not in this one.

The expected sequence is `see → truth → see → future → begin`. The repeated
`see` is a separate slot and must not be deduplicated. The table also contains
the four-Glyph prefix as a complete sequence, so the prefix alone remains
ambiguous after four observations. Known sequence length would be additional
evidence; the current predictor does not consume it.

## What this establishes

Each sampled visible presentation frame contains its complete expected edge
set. The shape persists for roughly 0.25-0.30 seconds per slot on this sample
grid, separated by blank samples. For this clip, recovering stroke direction
or accumulating a moving head is unnecessary to recognize the presented shapes.
Faster transitions below the 50 ms sampling interval remain unmeasured.

The command-channel gesture before presentation and player input afterward
show substantially different trails/particles. Representative samples at
23.600 and 28.550 seconds have a geometrically matching subset but are downgraded
to `unexplainedInk`. This demonstrates the new ink check; it is NOT proof that
all player input will be rejected. Clean input can look exactly like a presented
Glyph and must be excluded by a game-phase tracker.

## Limits and regression coverage

- This is one manually annotated recording, with four distinct shape names.
  It is not a general accuracy estimate or validation of all 142 game shapes.
- Labels were obtained from visible geometry and the reference definitions;
  the clip does not display a name next to each Glyph or a final scored result.
- Phase and slot boundaries were annotated manually. The replay does not
  implement automatic segmentation, OCR, live capture integration, or device
  performance measurement.
- The unrelated 160 samples outside the annotated presentation interval are
  retained for diagnostics, not scored as presentation positives/negatives.
- No thresholds were tuned to make this recording pass. The review fixes were
  in place before these presentation samples were analyzed.

Eight compact PNG fixtures preserve calibration, the five slots, a command
trail, and player input. `RecordingRecognitionTests` checks real pixel matches,
explicit completion, repeated Glyphs, and prediction integration. The replay
script checks all 40 annotated samples, including blanks.

## Reproduce

From the repository root, build the release executable in the package:

```sh
swift build --package-path Packages/GlyphRecognition --build-system native -c release --product glyph-recognize
python3 Tools/check-recording.py 'ScreenRecording_09-17-2026 23-56-50_1.MP4' \
  --output Tools/RecordingResults/2026-09-17
```

The script needs Python 3.11+ and ffmpeg. Add `--save-fixtures` only to regenerate
the eight selected PNGs. It does not change the source video.
