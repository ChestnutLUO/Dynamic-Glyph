# Phase and slot replay: 2026-09-18

Source: `ScreenRecording_09-17-2026 23-56-50_1.MP4` in the repository root, the
same clip as the [2026-09-17 recording validation](../../RecordingResults/2026-09-17/README.md).
Machine-readable result: [phase-replay.json](phase-replay.json).

## What is different from the earlier replay

The earlier replay supplied the phase and the slot boundaries by hand, and
checked only that the shape recognizer named the right Glyph in each annotated
frame. This one supplies **nothing**. Each of the 200 frames goes through the
live pipeline in order:

1. `GlyphFrameSession` — calibration and shape recognition, unchanged.
2. `SlotStripReader` — the number of hexagonal slot indicators and which one is
   gold, read from the colour pixels of the top band.
3. `HeaderTextRecognizer` — Vision text recognition over the header region,
   matched against the four English phrases.
4. `PresentationTracker` — the state machine that decides what, if anything,
   joins the sequence.

The expected sequence is the manual annotation of what the screen showed. It is
compared against the result and never fed into it.

## Result

**All five slots recovered, in order, from pixels alone.**

| Slot | Glyph | Supporting samples | Boundary that closed the slot |
| --- | --- | --- | --- |
| 1 | see | 5 | indicator advanced to slot 2 |
| 2 | truth | 6 | indicator advanced to slot 3 |
| 3 | see | 6 | indicator advanced to slot 4 |
| 4 | future | 5 | indicator advanced to slot 5 |
| 5 | begin | 6 | presentation ended, player input began |

- Slot count **5**, detected from the indicator strip, not inferred from the
  number of Glyphs recognized.
- The repeated `see` is preserved as two separate slots.
- Sample counts match the 2026-09-17 report's per-slot correct-frame counts
  (5, 6, 6, 5, 6) exactly, from an independent path.
- With five slots known, the sequence table resolves to a single candidate.
  Without the slot count it would not: the four-Glyph prefix is itself a
  complete sequence in the table.
- One hack was tracked; the tracker finished in the `input` state, with the
  sequence frozen at the presentation-to-input transition.

## Phase classification over the clip

| Header phase | Frames |
| --- | --- |
| command | 55 |
| presenting | 50 |
| input | 41 |
| unknown | 54 |

The 54 unknown frames are the map and the transitions at the start of the clip,
before the command channel opens. The indicator reader refused those frames as
well (44 `inconsistentMarkerWidths`, from bright map clutter forming runs of the
wrong width) and refused all 55 command-channel frames as `noMarkers`, because
that screen has no indicator strip. Both refusals are the wanted behaviour: no
phase is guessed, and no slot is opened outside a verified presentation.

## What this does and does not establish

- It establishes that the boundaries can be derived from pixels on this clip,
  end to end, with no manual annotation in the loop.
- It is one recording of one hack, in the English portrait layout, at 20 Hz.
  It is not an accuracy estimate over the 142 shapes or over other layouts.
- It says nothing about device throughput. Every timing here is a Mac replaying
  PNG files, with text recognition run on every frame rather than on the
  bounded schedule the app uses.
- Frames come from `ffmpeg` at a fixed 20 Hz and are resized to 603 × 1311; the
  live capture's timing and scaling are its own.

## Reproduce

```sh
swift build --package-path Packages/GlyphRecognition --build-system native \
  -c release --product glyph-replay
python3 Tools/check-phase-replay.py 'ScreenRecording_09-17-2026 23-56-50_1.MP4' \
  --output Tools/PhaseReplayResults/2026-09-18
```

Needs Python 3.11+ and ffmpeg. The script exits nonzero if the recovered
sequence or the slot count disagrees with the annotation. It does not modify
the source video.
