# Ablation study: 2026-09-22

Every recording with a hack in it was replayed through the whole live pipeline
(`glyph-replay`), once as it is and then with one component switched off at a
time. Each run was scored against a manual annotation of what the screen
showed. Machine-readable results: [ablation-results.json](ablation-results.json).
Annotation: [annotations.json](annotations.json).

## Data

Five recordings, twelve hacks, **47 slots whose Glyph is visible in the
capture**. Ten hacks are complete. In the other two, capture gaps swallowed
most of the presentation.

| Hack | Sequence | Screen condition |
| --- | --- | --- |
| s0917-1 | see truth see future begin | 603×1311, nothing covered |
| s0918-1 | clear mind · · · | capture gap after slot 2 |
| s0918-2 | shapers portal · · · | capture gap after slot 2 |
| s0918-3 | shapers portal message destroy civilization | window over the strip for slots 1–3, then across the array |
| s0918-4 | forget attack see distance harmony | nothing covered |
| s0922-1 | hide chaos not body | 562×1218, header covered, strip visible |
| s0923a-1…5 | all chaos not body · shapers portal mind restraint · portal change civilization end · avoid xm message lie · attack weak shapers lie | header covered, strip visible; s0923a-5 is presented slowly (≈1.75 s per slot) |
| s0923b-1 | nzeer shapers resistance knowledge | header **and** strip covered |

The labels come from contact sheets of every sampled frame. Each drawn shape
was compared by eye with the reference diagram of its name, and every complete
sequence was then found as a row of `glyph.csv`. None of them came from the
recognizer. The annotation is only compared against and never feeds a run.

## How a run is scored

Each hack is probed **1.2 s after its last Glyph disappears**, when the player
has just started input. At that moment:

- **correct**: confirmed slots holding the annotated Glyph.
- **inferred ✓**: correct Glyphs held only as dashed inferred entries. These
  are excluded from prediction.
- **wrong**: a slot holding a Glyph other than the annotated one, confirmed or
  inferred. This is the failure that matters most, because the display shows
  it with confidence.
- **exact hacks**: complete hacks whose whole sequence and slot count are
  right.
- **spurious / late**: slot commits outside every presentation window. A late
  commit is the right Glyph for the right slot, but only after the probe.
- **latency**: from the last Glyph disappearing to its slot being committed,
  median over exact hacks.

## Results

| variant | correct | inferred ✓ | wrong | not recovered | exact hacks | slot count | spurious | late | median latency |
|---|---|---|---|---|---|---|---|---|---|
| **baseline** | **35/47** | 0 | **0** | 12 | **8/10** | 11/12 | 0 | 0 | 0.15 s |
| − header text | 34/47 | 0 | 0 | 13 | 8/10 | 8/12 | 0 | 0 | 0.15 s |
| − slot strip | 0/47 | 10 | 1 | 36 | 0/10 | 0/12 | 0 | 0 | – |
| − countdown bar | 19/47 | 0 | **16** | 12 | 4/10 | 11/12 | 0 | 0 | 0.13 s |
| − header − countdown | 18/47 | 0 | **16** | 13 | 4/10 | 9/12 | 0 | 0 | 0.13 s |
| − layout check | 35/47 | 0 | 0 | 12 | 8/10 | 11/12 | 0 | 0 | 0.15 s |
| − calibration cache | 1/47 | 0 | 0 | 46 | 0/10 | 5/12 | 0 | 0 | – |
| − ink check | **36/47** | 0 | 0 | 11 | 8/10 | 11/12 | 0 | 0 | 0.15 s |
| − stability rule | 35/47 | 0 | 0 | 12 | 8/10 | 11/12 | 0 | 0 | 0.15 s |
| − slot-count votes | 35/47 | 0 | 0 | 12 | 8/10 | 11/12 | 0 | 0 | 0.15 s |
| − indicator-established presentation | 11/47 | 0 | 0 | 36 | 2/10 | 5/12 | 0 | 0 | 0.15 s |
| − last-slot release | 34/47 | 0 | 0 | 13 | 7/10 | 11/12 | 0 | 1 | 0.70 s |
| − countdown − last-slot release | 17/47 | 0 | 12 | 18 | 2/10 | 11/12 | 0 | 0 | 0.70 s |
| 10 Hz sampling | 35/47 | 0 | 0 | 12 | 8/10 | 11/12 | 0 | 0 | 0.23 s |
| 5 Hz sampling | 21/47 | 0 | 0 | 26 | 3/10 | 11/12 | 0 | 0 | 0.30 s |
| 5 Hz − stability rule | 35/47 | 0 | 0 | 12 | 8/10 | 11/12 | 0 | 0 | 0.37 s |

### The baseline makes no errors, and every loss is a coverage loss

All 12 slots the baseline misses were never readable in the capture:

- Two capture gaps (s0918-1, s0918-2).
- The window over the strip and then the array (s0918-3, four slots).
- Header and strip both covered (s0923b-1, four slots).

There are no wrong slots, no spurious commits, and no recognition error on any
Glyph that was cleanly visible.

## What each component contributes

**Essential**

- **Calibration cache**: 35 → 1. Fitting the array afresh on every frame fails
  as soon as strokes cover the rings. Acquiring the fit on an empty array and
  reusing it is what recognition rests on.
- **Slot strip**: 35 → 0 confirmed. Where the header can be read (s0917,
  s0918), the blank-interval fallback recovers 10 Glyphs as dashed entries,
  with no slot count and no prediction. It also places one Glyph in the wrong
  slot: `civilization` lands in slot 1 of s0918-3. Where the header is covered
  it recovers nothing.
- **Indicator-established presentation**: 35 → 11. In the three 562×1218
  recordings the header was never read: all 4,023 frames returned `unknown`.
  All six hacks there, 24 correct slots, depend on the stable-empty-strip →
  slot-0 path. Picture in Picture over the header is the app's normal
  configuration, so this is the path real use runs on.
- **Countdown bar**: 0 → **16 wrong slots**. This is the most serious failure
  found. With the header covered, the countdown bar is the only thing that
  freezes a hack. Without it, the tracker leaves each presentation as
  `interrupted` rather than `input`, and never freezes. When the next hack
  shows the same number of slots, `shouldStartNewHack` treats it as the
  interrupted hack resuming. Its settled slots then cannot be overwritten, so
  hacks 2–5 of s0923a all show hack 1's `all chaos not body`, as confirmed
  entries.

**Latency, with some redundancy**

- **Last-slot release**: correctness is unchanged apart from one slot, but the
  median latency goes from 0.15 s to 0.70 s. In the slowly presented s0923a-5,
  `lie` is not committed until input begins, 2.9 s after it disappears. The
  rule and the countdown bar back each other up: with both off, all six last
  slots are lost on the header-covered recordings.
- **Header text**: one slot and three slot counts, all in s0918, where the
  presentation was joined without its strip prelude (after a capture gap, or
  with the window over the strip). It adds nothing when the strip prelude is
  visible, and on the 562×1218 layout it never reads at all.

**No measurable benefit on this data**

- **Ink check**: switching it off *gains* a slot. The window sliding across the
  array during `destroy` (s0918-3) left unexplained bright pixels, which
  downgraded a correct match. It prevented no error here. Its job is to reject
  command and input trails if the phase tracker ever lets them through, and
  the phase tracker never did in these recordings.
- **Stability rule, slot-count votes, layout check**: no effect at 20 Hz. No
  transient wrong shape, miscount or mismatched layout occurred for them to
  stop. They are untested safeguards, not demonstrated ones.
- **Node splitting** was not run. Only one of the 142 templates (`imperfect`,
  `536546`, whose 4→6 line passes over 5) depends on it; every other template
  already lists its intervening nodes. `imperfect` appears in no recording, so
  switching the splitting off could not change any result.
- **Nested-growth resolution** was not run either: it never fired in a
  baseline replay. The game draws each presented shape whole, so no slot held
  two nested stable shapes.

**Sampling rate**

- **10 Hz** loses nothing while the strip is readable, and adds 0.08 s of
  median latency. With the strip covered it loses the whole fallback: the
  blank between two Glyphs lasts about 100 ms, which at 10 Hz is one sample,
  and the fallback needs two to separate shapes. The 10 correct dashed entries
  at 20 Hz become 0, each hack merging into one uncertain slot (measured
  after the tracker fix below, as the "10 Hz − slot strip" variant).
- **5 Hz** loses 14 slots, and the stability rule is the entire cause. A shape
  visible for about 0.3 s yields one or two samples, and a slot whose only
  shape was seen once is closed as `uncertain`. With the rule relaxed, 5 Hz
  recovers all 35 slots, at 0.37 s latency.

**Prediction with the slot count**

For the eight exact hacks, the table names the whole sequence after
**2.0 confirmed Glyphs on average with the slot count, against 2.9 without it**.
The biggest case is s0917-1, which resolves after 2 Glyphs rather than 5,
because its four-Glyph prefix is itself a complete sequence. No prefix ever
resolved to a wrong sequence while the confirmed prefix was right. The 16
wrong resolutions in the countdown ablations come from the stale sequence
above, not from the table.

## Recommendations

1. **Don't let hack separation rest on the countdown bar alone.** With the
   header covered, one missed bar makes the tracker show the previous hack's
   answer as confirmed for every later hack of the same length. A fresh
   stable-empty-strip → slot-0 prelude while the held slots are already
   settled is itself evidence of a new presentation. `shouldStartNewHack`
   could treat it as one, instead of as a resume. This needs its own tracker
   test and a rerun of this study.
2. **Keep sampling at 20 Hz.** 10 Hz first looked free here, but that was
   measured only with the strip readable; with the strip covered it disables
   the fallback (see Sampling rate). The phone keeps 20 Hz comfortably:
   backgrounded recognition had a 17 ms p95 in the 2026-09-18 field run.
3. **Reconsider the ink check's cost.** It removed a correct Glyph and stopped
   nothing. It is still the only defence if phase tracking ever fails, so
   keep it. But a window crossing the array is a known case, and today
   nothing detects a window over the array; only the strip has that check.
4. **Header text is a fallback in the configuration people actually use.**
   Its value is in joining a presentation whose strip prelude was missed. A
   bounded schedule for it, rather than per-frame reading, loses nothing
   measured here.

## Verification after the tracker fix

The fix makes a newly verified empty-strip → slot-0 transition start a new
hack instead of resuming, **but only once the strip has been out of sight for
`minimumStripAbsenceForNewHack` (1.5 s) since the tracker was last in
presentation**. The first version had no such condition. It separated the
recorded hacks, but it could not tell a new prelude from this hack's own
released tail: one unreadable strip frame in the tail, a missed countdown, and
input lighting slot 0 made it discard the answer and collect the player's
strokes as confirmed slots. `tailFlickerIsNotANewHack` now pins that case.

The full study, with a "10 Hz − slot strip" variant added, was rerun against
the same annotations. Results are in
[post-fix-results.json](post-fix-results.json); the table above and
`ablation-results.json` remain the **pre-fix** baseline for comparison.

| Variant | Before | After |
| --- | --- | --- |
| Baseline | 35/47, 0 wrong, 8/10 exact | unchanged |
| Without countdown | 19/47, 16 wrong, 4/10 exact | 35/47, 0 wrong, 8/10 exact |
| Without header and countdown | 18/47, 16 wrong, 4/10 exact | 34/47, 0 wrong, 8/10 exact |
| Without countdown and last-slot release | 17/47, 12 wrong, 2/10 exact | 29/47, 0 wrong, 2/10 exact |
| 10 Hz − slot strip | not run | 0 correct, 0 dashed ✓, 1 wrong |

The other variants are unchanged. Countdown detection still matters: it
closes the last slot when the release rule cannot, and a long capture
interruption with the countdown missed is not covered by these recordings.

## Limits

- Twelve hacks from one player's sessions on two devices. This finds which
  components carry the load on this data. It is not an accuracy estimate, and
  a component with no effect here is untested, not proven redundant.
- The replay runs on a Mac from the H.264 recordings. The recorder captured
  the same frames the phone analysed (2622 recorded against 2623 analysed in
  the 2026-09-18 field report), but decoding differs from the live buffers,
  and header text is read on every frame rather than on the app's schedule.
- Probe moments and presentation windows come from the annotation. They are
  approximate to about one sample (50 ms), well inside the 1.2 s probe offset
  and the 0.3 s commit lead.
- One person annotated, by eye. Every complete sequence is a row of the
  sequence table, which independently checks the reading.

## Reproduce

```sh
swift build --package-path Packages/GlyphRecognition --build-system native \
  -c release --product glyph-replay
python3 Tools/check-ablations.py --output Tools/AblationResults/2026-09-22
```

This needs Python 3.11+, ffmpeg, both reference tables, and the raw recordings
named in `annotations.json`. Those recordings are gitignored device evidence.
A full run replays about 7,400 frames for each of the 17 variants, and took
about 6 minutes on a 10-core Mac.
