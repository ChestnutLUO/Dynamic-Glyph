# Player input validation

Status: v1 implemented; the replay and verification results below describe the
current evidence. Deliberate-mistake recordings and broader Redo validation
remain future work; one reported Redo capture is analyzed below.
Selected behavior for the first version: check each completed Glyph after the
player lifts, for every slot except the last. Live warnings while drawing and
actionable "Redo" wording are deferred until recordings support them.

## What the recordings show

The first draft of this design assumed player strokes look like presentation
strokes. They do not. `IMG_2003.MP4` (repository root, 880 x 1914, one 5-slot
hack) was replayed at 20 Hz, 562 px wide, through `GlyphFrameSession` and
`SlotStripReader`. The game presented `shield, mind, clear_all, chaos, xm` and
the player drew all five correctly. Times below are seconds into that video.

- **The trail is the finger's path, not a lattice line.** Segments bow between
  nodes, the head of the stroke is a curved pink segment, and the whole trail
  carries glow and particles. The recognizer samples a thin straight line per
  lattice edge and reports an edge at 80% coverage, so a bowed stroke can light
  an edge that was never drawn.
- **Transient off-template edges persist.** Drawing `shield`, edge `4-a` was
  present in 13 consecutive samples (9.15–9.75 s). Drawing `mind`, edge `5-6`
  was present in 3 samples spanning 100 ms (11.00–11.10 s). Both drawings were
  correct.
- **Most input frames are `unexplainedInk`.** 186 of 401 samples between 7 and
  27 s. The particles leave ink no detected edge explains.
- **The indicator advances on lift, and the finished drawing stays.** After the
  player lifts, the gold highlight moves to the next slot while the completed
  drawing remains on the array until the next stroke touches down:

  | Drawn | Highlight advanced | Array cleared | Frames exactly matching the drawn Glyph after the advance |
  |---|---|---|---|
  | shield | 9.70 | 10.25 | 9 (0 `uniqueVisibleShape`) |
  | mind | 11.60 | 13.50 | 36 (5 `uniqueVisibleShape`) |
  | clear_all | 16.45 | 17.15 | 14 (3 `uniqueVisibleShape`) |
  | chaos | 18.55 | 20.55 | 40 (8 `uniqueVisibleShape`) |

  In those frames the transient `4-a` had faded below threshold, and every
  frame exactly matched the expected Glyph. They are the most reliable evidence
  the capture offers.
- **The clear between strokes can be a single sample.** At 13.50 and 17.15 s
  exactly one 20 Hz sample shows a clear array. A faster player may leave none.
- **The game shows its own result immediately after the last Glyph.** The strip
  disappeared at 22.50 s and the completion screen named each Glyph with the
  hacking bonus. That screen also produced a false exact `link` match
  (22.5–25.3 s).
- **The input screen has Redo, ⊗ and Done controls.** They are visible in
  `spikeB-2026-09-23T00-14-36Z`. In `IMG_2003.MP4` the floating window sat
  directly over that row for the whole input phase. Neither recording presses
  Redo, so those recordings do not establish what it resets. Later captures
  document backward slot transitions below; the number of button presses and
  reset behavior must not be inferred from a returned highlight alone.

This is one hack, one player, one device, and no mistakes. It measures false
warnings on correct drawings, not detection of real errors.

Consequences for the design:

1. A rule that warns on any extra edge held for three samples over 100 ms would
   have warned on two of five correct Glyphs. That rule is withdrawn.
2. A union of every edge seen during an attempt locks in transients such as
   `4-a`. The verdict is taken from post-lift frames, not the union.
3. Frames under the next slot's highlight belong to the previous drawing until
   the array clears. Discarding them discards the best evidence.
4. `unexplainedInk` cannot mean "unable to check" during input, or nothing
   would ever be checked.
5. A verdict on the last slot arrives after the game's own. It is out of scope.

## Player experience

Keep the expected sequence visible while the player draws. When a completed
Glyph reliably differs from the confirmed expectation, mark that slot with a
red outline and an exclamation mark. Keep its expected diagram visible so the
player can see what was intended. A warning never replaces the expected shape
with the drawn one.

Use a compact symbol in the floating window: its existing renderer deliberately
avoids small captions because they were illegible on device. In the expanded
Island and app, show the slot number, expected Glyph name and a short message.
Do not open a modal over the game or require a dismissal.

| Situation | Message where text fits | Floating window |
|---|---|---|
| Drawing in progress | Normal input guidance | Normal current-slot outline |
| Completed Glyph matches | “Glyph 3 matches” | Brief check mark on slot 3 |
| Completed Glyph differs | “Glyph 3 differs — expected TRUTH” | Warning outline and `!` on slot 3; expected diagram stays visible |
| Evidence cannot support a comparison | “Unable to check Glyph 3” | Neutral `?`; expected diagram stays visible |
| Last slot | Normal input guidance; no verdict | No verdict mark |

These are example strings with placeholders, not hardcoded Glyph names. Localize
the implemented strings in all supported languages following TRANSLATION.md.
Use symbols and text alongside color. Start with visual feedback; sound or
background haptics require a separate device feasibility check.

A verdict appears once, when its slot's attempt ends, and stays attached to
that slot while the next slot is highlighted. Replace it only with a verdict for
a verified new attempt on the same slot, or with “Unable to check” when that
attempt is lost. Retain superseded results only in diagnostics. Clear all
results on a new hack or capture session.

The app observes the game; it does not submit, erase or redraw input. The first
version never tells the player to redo anything. “Redo Glyph 3 — draw TRUTH”
becomes allowed only when all of these hold:

- Recordings establish what the game's Redo control resets and while it stays
  available.
- The control is observed on the current frame, the way the countdown bar is,
  rather than assumed.
- The floating window is not covering it. Placement guidance should keep the
  window off the Redo / Done row, as it already asks for the slot row.

## When a comparison is allowed

The first version checks against **confirmed presentation slots only**.
Predicted, inferred, missing and uncertain slots can still provide existing
guidance, but cannot establish that the player made an error. A prediction is
not a ground-truth answer. A confirmed slot after a gap is checkable; it does
not need to be part of the confirmed prefix.

Require all of the following:

- The current hack's presentation was observed and input is now active.
- The attempt's slot was identified from a fresh, unambiguous strip reading,
  with no count conflict or obstructed indicators, both when it began and when
  it ended.
- That slot has a confirmed expected Glyph and is not the last slot.
- Frame timestamps, calibration and capture continuity are valid across the
  attempt.
- The attempt's start was observed (see below). A drawing first encountered
  halfway through is not checked.

Use current-frame evidence to corroborate input phase, as the presentation
tracker already does. Suppress comparisons when the slot is lost; do not
attribute later pixels to the last remembered slot.

## Attempt boundaries

Screen capture provides pixels, not touch events. The recording shows two
independent pixel boundaries per attempt, and the design uses both:

- **Start: the array clears, then new ink appears, while slot k is highlighted.**
  Touch-down on the next stroke removes the previous drawing. Accept a single
  clear sample as the start; do not reuse the tracker's two-sample
  `minimumBlankInterval`, which the recording would miss. If no clear sample is
  seen between one drawing and the next, the new attempt's start is unobserved
  and its verdict is “Unable to check”.
- **End: the highlight advances from k to exactly k + 1.** Debounce it as a
  strip reading, requiring two agreeing samples. A jump of more than one slot
  leaves every slot involved unchecked. A move backwards is not an end: it
  invalidates any verdict for the slots it returns to and waits for a new
  observed start.

Frames between the end and the next clear belong to slot k, even though the
strip now highlights k + 1. That window, called the post-lift window below, is
where the verdict is taken. It ended between 0.55 and 1.95 s after the advance
in the recording.

The next touch-down can erase the old drawing and add new ink within a single
sample. In the Redo capture no clear sample separated `path` from `destiny`;
the first sample after `path` held ink that reached no lattice edge. A
post-lift sample with no present edge therefore ends the window exactly as a
clear does, and counts as the next attempt's observed start.

The last slot has no advance; the completion screen follows it. It gets no
verdict. Leaving input, a command screen, a completion screen, strip loss or a
source-time gap ends every open attempt as unchecked.

## Comparison rules

Compare undirected edge sets. The recognizer already reports elementary edges,
so only the expected side needs `GlyphGeometry.normalizedEdges`; take it from
the same templates `GlyphFrameRecognizer` builds rather than recomputing them.

Let `E` be the expected edges. For each sample in the post-lift window, read
that sample's present edges `F`, regardless of whether the frame was classified
`uniqueVisibleShape`, `unexplainedInk` or `unrecognizedStroke`. The drawing is
the edge set of the post-lift samples, not the union of the attempt.

Read the window as runs of consecutive samples with an identical `F`. A run is
**stable** when it holds at least 3 samples spanning at least 100 ms and `F` is
not empty. Shorter runs are the drawing settling after lift and do not vote: in
the recording a correct `shield` kept `4-a` for its first 2 post-lift samples,
and a correct `mind` lacked `5-a` in 3 of its first 4.

| Stable runs in the post-lift window | Verdict | When it is shown |
|---|---|---|
| One reading, `F == E` | Matches | As soon as the run is stable, while the drawing is still up |
| One reading, `F != E`, held for at least 5 samples spanning at least 200 ms | Differs | Only when a clear (or an edge-free sample) ends the window |
| That reading lacks an expected edge that was at least 30% lit in any of its samples | Unable to check (`partialEdge`) | When the window ends |
| Two or more different readings | Unable to check | As soon as the second one is stable; it withdraws a shown match |
| None, or a wrong reading held too briefly for “differs” | Unable to check | When the window ends |

An edge counts as present at 80% coverage. A freehand stroke bows away from
the straight line sampled between two nodes, so a drawn edge can fall short of
that and still be well lit. A wrong reading is therefore evidence of a wrong
drawing only when every expected edge it lacks was clearly dark, below 30%, in
each of its samples. Extra edges already have to be fully present to be read.
Check partial support across every stable run of that reading, including runs
of only 3 samples over 100 ms. The longer 5-sample / 200-ms requirement permits
a mismatch warning; it must not discard uncertainty from a shorter stable run
separated by a brief recognition flicker.

The rule is deliberately asymmetric. A match can be shown early, so the player
sees it before starting the next Glyph; a mismatch needs a longer run and a
closed window, because a false error costs more than a late one. A match
already shown stands if the window is then interrupted (a gap, strip loss, a
phase change), since the samples that established it were fully observed.
Without a stable reading, an interrupted window is “Unable to check”.

The per-sample threshold stays as the recognizer's, and no rule relaxes because
a boundary arrived.

The window will usually be shortest when the player is fastest. A player who
starts the next stroke within 100 ms of lifting will get “Unable to check”. That
is the intended trade: missed checks are acceptable, false errors are not.

Nearest-template distance is not a confidence probability. “Matches” means our
comparison succeeded; it does not claim the game awarded the Glyph.

Evidence gathered while the stroke is in progress is kept for diagnostics only.
It may later support live warnings, but only after the replay harness shows an
acceptable false-warning rate on correct drawings, which the threshold proposed
in the first draft did not.

## Implementation layout

Add a separate, framework-free `PlayerInputValidator` in `GlyphRecognition`.
`PresentationTracker` remains the owner of the remembered sequence. Validation
must never mutate its slots, confirmed prefix, predictions or phase decisions.

The validator accepts, per frame: the `FrameEvidence` the tracker received,
the tracker's state after accepting it (state, hack ID, slots, count conflict,
obstruction), and the frame's per-edge evidence. Read the highlight from
`FrameEvidence.slots`, not `tracker.inputSlotIndex`, which is display-only and
nil whenever any slot is inferred. `ShapeEvidence` keeps the present-edge set
but drops coverage; pass the `GlyphEdgeEvidence` array alongside it for
diagnostics and future tuning rather than widening `ShapeEvidence`.

Proposed output:

```swift
enum InputCheckVerdict {
    case matched, differs, unavailable(InputCheckUnavailableReason)
}

// One result belongs to (captureSessionID, hackID, slotIndex, attemptID).
// It carries expectedGlyph, verdict, sourceTime of the deciding sample, and,
// for diagnostics, the post-lift edge sets, the boundary that ended the
// window and the attempt's start and end times.
```

Unavailable reasons include unconfirmed expectation, last slot, missed start,
multi-slot jump, backward move, short post-lift window, disagreeing samples,
frame gap, strip loss and phase change.

Wire it into `LiveGlyphOutput` after the tracker accepts each frame. Pass its
results through `GlyphDisplaySnapshot`, then use the same values for the app,
`GlyphDisplayRenderer` and Live Activity. Snapshot revision includes result
changes. The Picture in Picture render key is assembled by hand in
`GlyphPiPRenderLoop`; add the results to it, or a verdict will not redraw while
the sequence is unchanged. Add a per-slot verdict to
`GlyphActivityContentState`, and reuse the Activity update scheduler's
coalescing. Verdicts carry source time; cached frames and delayed Activity
updates must not move them to another slot.

Add attempt boundaries, post-lift edge sets and verdicts to the optional
session logs, so recordings can be scored offline.

## Verification before release

Pure tests must cover:

- The recorded shapes: `shield` with a transient `4-a` during drawing and a
  clean post-lift window matches; `mind` with a 3-sample `5-6` during drawing
  matches.
- A stable wrong reading of at least 5 samples produces “differs” only when
  the window closes; two different stable readings, or no stable reading,
  produce “Unable to check”; a match is shown as soon as its run is stable and
  is withdrawn by a later different stable reading.
- The recorded post-lift sequences for `shield` and `mind` match.
- A sample with ink but no lattice edge ends a post-lift window.
- Frames under slot k + 1's highlight before the clear are attributed to slot
  k; the first ink after the clear starts slot k + 1.
- A single clear sample starts an attempt; no clear sample leaves the next
  attempt unchecked.
- Multi-slot jumps, backward moves, repeated Glyphs, frame gaps, strip loss and
  the completion screen keep verdicts attached to the correct slot or withhold
  them.
- The last slot, predicted and inferred expectations never produce a verdict.
- Player input never changes the retained presentation or sequence prediction.
- Verdict changes redraw every surface.

Extend `glyph-replay` to run the validator and print one verdict per slot, then
check it against annotated recordings:

1. `IMG_2003.MP4` as the correct-drawing baseline: every checked slot must be
   “matches” or “Unable to check”, never “differs”.
2. New recordings with deliberate mistakes: an extra edge, a missing edge, a
   wrong complete Glyph, a fast start on the next stroke, a covered strip.
3. A recording that presses Redo, to establish what it resets and when the
   control is shown.

Report false “differs” on correct Glyphs, missed deliberate errors, and how
often each unavailable reason occurs. Tune the sample count and span from this
evidence, not from the presentation tracker's thresholds.

## Delivery order

1. Replay harness and annotated recordings, including deliberate mistakes and a
   Redo press.
2. `PlayerInputValidator` with post-lift verdicts and the tests above.
3. Surface the verdicts on the floating window, Island and app.
4. Only if recordings support them: live warnings while drawing, and “Redo”
   wording once the control's behavior and visibility are verified.

## v1 implementation notes

`PlayerInputValidator` runs independently after `PresentationTracker.accept` in
both capture and replay. It reads the current strip directly, uses the
recognizer's normalized expected template, and retains each post-lift sample
separately. The two samples confirming the advance are retained in the window;
there is no unmeasured settling delay that discards their edges. A match is
published with `windowEnd: open` as soon as its run is stable, then finalized
with the same source time when the window ends, so closing it neither restarts
the check mark nor moves the verdict.

The first v1 rule required every post-lift sample to agree. On the baseline it
left `shield` and `mind` unchecked, because of the settling samples described
above, and it published every verdict at the next touch-down, 0.55–2.0 s after
lift, when the player was already drawing the next Glyph. The stable-run rule
replaced it. Replaying the full correct-drawing baseline at 20 fps / 562 pixels
wide now produces:

| Slot | Expected | Result | Post-lift runs | Shown after lift |
|---|---|---|---|---|
| 1 | shield | Matches | 2 with `4-a`, then 9 matching | 0.20 s |
| 2 | mind | Matches | 4 settling (3 lack `5-a`), then 35 matching | 0.30 s |
| 3 | clear_all | Matches | 14 matching | 0.10 s |
| 4 | chaos | Matches | 40 matching | 0.10 s |
| 5 | xm | No verdict | Last slot is excluded | — |

The false `differs` count is zero. `recordedTransients` in
`PlayerInputValidatorTests` replays these exact post-lift runs.

Unavailable results are not correctness verdicts. Attempts on eligible
confirmed slots that lift but cannot be judged display “Unable to check”. An
attempt lost before lift (one unreadable strip frame, a highlight flicker)
displays nothing while the player is still drawing; sampling that resumes
mid-stroke starts a new attempt with an unobserved start, which reports “Unable
to check” once it lifts. Last and unconfirmed slots have no display result.
Multi-slot jumps submit nothing new, and verified backward moves remove results
at and beyond the returned slot. An advance before any clear closed the window
is logged as `unclosedWindow`. Idle capture frames are not passed to the
validator: an unchanged screen is not lost geometry.
Source-time gaps over 100 ms invalidate continuity; duplicate timestamps do
not vote. These policy values remain subject to further recording evidence.

Results carry session, hack, slot, attempt and source-time identity. They update
the snapshot revision, PiP render key and per-slot Live Activity payload.
Matched symbols expire after 1.5 seconds; historical results remain attached to
their slots. The expanded Island footnote and the in-app line show the latest
verdict only while its slot mark is shown, the Island only during input, and
never ahead of the provisional-sequence warning. Mismatches use an outline and `!`, unavailable results use `?`, and
the expected diagram stays visible. Expanded text is localized through the
recognition package in English, Japanese and both Chinese variants.

With bug-report recording enabled, `input-validation.jsonl` records starts,
lifts, individual drawing/post-lift edge support and final results. Replay
exposes the same diagnostics in `inputEvents` and `inputChecks`; the
`--expect-correct-input` assertion fails on any `differs` or on no checks.
Run `Tools/check-input-validation.py` to reproduce the baseline, as described
in [Tools/README.md](../Tools/README.md).

Deliberate-error detection, broader Redo behavior, and the actual on-device visibility
and delivery latency of the new marks are not established by this baseline.

Verification of the stable-run rule on 2026-09-23: 220 package tests passed on
macOS with `GLYPH_REQUIRE_REFERENCE_DATA=1`; all 53 app tests and the same 220
package tests passed on the iOS 27 simulator. `Tools/check-input-validation.py`
reproduced the table above with no assertion failures.

## Follow-up: fifth Glyph disappears after Redo

The user identified `DynamicGlyph-spikeB-2026-09-23T07-51-46Z.zip` as a bug
report: after Redo, the fifth Glyph disappears while it is being drawn. This
captured build still exhibits the older countdown behavior; it contains no
input-validation log.
The source sequence is `shapers, see, complex, path, destiny`.

The original recognition log stops reporting the countdown at 42.44 seconds.
After the phase grace expires, the tracker enters `interrupted` at 43.14
seconds, even though the strip is readable and calibration remains valid.
The fifth slot becomes highlighted at 43.54 seconds. Guidance requires input
phase, so it has already been withdrawn. The visible countdown is magenta by
this point; the older detector only counted gold progress pixels.

Commit `4fe5ca4` already fixes late countdown recognition, requiring the complete
violet track and accepting magenta progress. No phase-retention relaxation or
extra Island update frequency is needed to fix this observed loss of guidance.

The follow-up replay uses all 440 original recorded frames from 27 to 49 seconds,
with their source timestamps and native encoded 602 × 1310 dimensions. It does
not duplicate frames to force a constant frame rate. Probe output now includes
the input slot, countdown reading and the shared `upcomingGuidance` result.

| Probe time (seconds) | Current slot (one-based) | Guidance | Phase |
|---|---|---|---|
| 40.7 | 4 | path, destiny | input |
| 41.0 | 3 | complex, path | input |
| 42.3 | 4 | path, destiny | input |
| 43.2 | 4 | path, destiny | input |
| 43.6, 44.5, 45.5, 46.5 | 5 | destiny | input |
| 46.7 | — | none | completed |

The backwards 4 → 3 transition is consistent with the reported Redo press.
Both attempts at slot 3 match separately; slots 1 and 2 also match. Under the
first v1 rule slot 4 was “Unable to check”: no clear sample separated `path`
from `destiny`, so `destiny`'s growing stroke joined `path`'s window. With the
stable-run rule and the edge-free boundary, a replay of the same 27–49 s
interval (resampled at 20 fps) matches `path` 0.10 s after its lift, and every
checked verdict is shown 0.10 s after lift. There are zero `differs` results
and still no last-slot verdict. These are
validator outputs, not independent annotations of drawing correctness.
This one capture does not establish what Redo does from every other state, or
justify actionable Redo wording in v1.

A new tracker/guidance regression covers the backwards move, redrawing, and a
long fifth-slot input phase. The full 213-test package suite passed with local
reference data required. Replay confirms the model now retains fifth-slot
guidance until completion; actual Island delivery and visibility still need a
phone retest with the current build installed. Raw frames, full logs and the
archive remain local device evidence and are not committed.

## Follow-up: a correct `truth` reported as different

`DynamicGlyph-spikeB-2026-09-23T23-00-56Z.zip` records a four-slot hack
(`truth, idea, discover, xm`). The player drew `truth`, pressed Redo and drew it
again. The result screen lit `truth` first and awarded its bonus, supporting
the human annotation that the final attempt was accepted. It does not judge
the superseded first attempt; the user annotated both drawings as correct.
The validator logged `differs` for both, at 24.06 and 27.41 seconds.

The logged attempts are 1/TRUTH, 2/IDEA, 3/TRUTH, 4/IDEA, and 5/DISCOVER.
`recognition.jsonl` first shows zero-based highlight 2 at 25.26 seconds,
then 1 at 25.66 and 0 at 25.91. The 25.31-second reading is a subsequent sample.
Frames from `screen-recording.mp4` at 20 Hz show two separate bright Redo-button
pulses, about 25.50–25.70 and 25.85–26.05 seconds, with a return to normal
between them and dimming after about 26.10. Annotate two apparent presses,
each stepping back one slot, assuming those pulses are press feedback. The
button and highlight evidence support this annotation together; the highlight
alone does not prove a press count or a whole-sequence reset. The button is
covered in IMG_2003.MP4, so this is not a required live detection signal.
The conclusion's TRUTH and IDEA refer to attempts 3 and 4, not 1 and 2.
Its annotated final bonuses are 120% Hacking
Bonus and 55% Speed Bonus. See RESULT_RECOGNITION.md for the result timeline,
classification gates, and the distinction between annotation and live claims.

After each lift the recognizer read every `truth` edge except 3-5: five samples
over 200 ms, meeting the mismatch rule exactly. Edge 3-5 is the stroke's first
segment and was lit at 58-62% on the first attempt and 75-79% after Redo,
short of the 80% threshold. It was read as present on the last frame before the
second lift, then faded below it. Only the present-edge set was kept, so a
well-lit edge and an undrawn one looked the same.

Each post-lift sample now also records its partial edges: below 80%, at least
30% lit. A mismatch whose missing expected edges were partial in any of its
samples is `Unable to check (partialEdge)`. `recordedTruth` in
`PlayerInputValidatorTests` replays both attempts' coverage, and
`partlyLitEdges` checks that a dark missing edge still produces `differs`.
`partialEvidenceAcrossRuns` covers a shorter stable run with partial support
before or after a longer dark run, separated by a one-frame flicker. Both
orders remain `partialEdge` rather than warning as the stroke fades.

Replaying that capture at 20 fps gives no `differs`: the first `truth` is
`partialEdge`, the second `shortWindow` at that resampling, and `idea` twice and
`discover` match. `IMG_2003.MP4` still matches all four checked slots and the
Redo capture all five. The 30% floor is a starting point: deliberate-mistake
recordings are still needed to measure how often a real missing edge is also
left partly lit, and so goes unreported.

A focused replay of the original timestamped edge observations and recognition
context through the validator at `02f75f9` yields `partialEdge` for attempts 1 and
3, with attempts 2, 4, and 5 matching. This checks the validator on the logged
evidence, not conclusion recognition, and is distinct from the resampled-video
replay above.


## Deliberate-error comparison capture

`5Glyphwitherrorglyphandredo.zip` contains session
`spikeB-2026-09-24T00-01-28Z`: OLD, NATURE, LESS, STRONG, NOW. The user reports
one wrong drawing and one Redo. `recognition.jsonl` shows highlight 2 → 1 at
16.981 s relative to the recording start. NATURE attempt 2 is superseded by
attempt 3. Final validator associations are 1/OLD, 3/NATURE, 4/LESS, 5/STRONG;
NOW remains outside the validator's final-slot scope.

The conclusion video shows a magenta STRONG contour and gold contours for the
other slots, with final **40% Hacking Bonus / 0% Speed Bonus**. The STRONG game
result agrees with `differs`; the other compared final attempts match. This is
one recorded error example, not a recall estimate. M1 conclusion diagnostics
compare these outcomes without changing PlayerInputValidator or attempt IDs.
See RESULT_RECOGNITION.md for the evidence, remaining wrong-last-slot gap, and
replay command.
