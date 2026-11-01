# Build 73: four October 2 recognition reports

Reviewed the private reports `DynamicGlyph-spikeB-2026-10-02T17-53-48Z`,
`18-00-57Z`, `18-03-00Z`, and `18-06-56Z`. The tester identified build **73**;
none of the reports contains a note. All four contain screen recordings.
Raw reports are extracted outside the checkout, under the recordings folder.
Only masked panel fixtures and owned replacement headings enter the repository.

## Recorded totals

Use the last result summary per hack; intermediate summaries are updates.
These are the original build's readings, not independent accuracy scores.

| UTC start | Hacks | Complete / partial / not observed | Gear groups | Both panels read | Recognized quantity |
| --- | ---: | --- | ---: | ---: | ---: |
| 17:53:48 | 2 | 1 / 0 / 1 | 2 | 0 | 3 |
| 18:00:57 | 3 | 3 / 0 / 0 | 4 | 2 | 36 |
| 18:03:00 | 6 | 2 / 2 / 2 | 6 | 3 | 39 |
| 18:06:56 | 14 | 12 / 2 / 0 | 15 | 6 | 134 |
| Total | 25 | 18 / 4 / 3 | 27 | 11 | 212 |

The first report additionally has one unidentified item. The last report's
quantity includes an incorrect eleven-shield reading; totals are what the app
claimed, not actual loot. A drop group is not a hack, and FIFO ownership remains
a hypothesis where ordinary hacks or unseen panels join the queue.

## 1. Pickup sparks make a visible Bonus panel disappear from geometry

In `18-00-57Z`, `gear-drops.jsonl` line 13 reads the Bonus panel at source
1134906.713284 (video 39.540 s). Line 14 closes its group at
1134907.063344 (39.890 s). Line 17 opens another group with the SAME Bonus
panel at 1134907.413403 (40.240 s). The video shows a continuously visible
panel containing three L8 Bursters, three L8 Resonators and three L7
Resonators. Purple pickup sparks cross its borders; it does not depart.

The detector demands 74/80 lavender samples across both horizontal strokes.
For video frames around 39.70–40.05 s, the first qualifying stroke is the
bottom at y=549, or no second stroke is found. The actual top remains y=375.
Even the title-background sample can be crossed by the same spark. The
0.15-second departure rule therefore splits the group, consumes two waiting
hacks, and leaves hack 2's real drop unattached.

**Fix:** retain the full-width detector, with an alternative requiring
half-width top/bottom strokes, both independently verified vertical sides,
and the dark title background on that half. Colour predicates and the
74/80 border and 34/40 background requirements stay unchanged. Separate
vertical segments tolerate a localized spark without discarding the side.
Masked top-/bottom-border regressions failed before the fix and pass after;
removing either side makes the alternative reject the image.

The report replays as **three complete groups**, quantities **13, 8, 15**,
attached to hacks **1, 2, 3**. Before the change it replayed as four groups,
quantities 4, 9, 8, 15, with only two complete groups. Item quantity remains
36; the correction is confirmation, grouping and attribution.

## 2. Pending OCR finishes after its group was published

In `17-53-48Z`, a Bonus read at source 1134505.350 (67.211 s) is logged
after group 1 closes at 1134506.900 (68.762 s). The last report has five
similar late completions, including Bonus evidence for group 4 at
1135390.565 (164.086 s), after closure at 1135391.915 (165.436 s).
Rows are logged in completion order; an earlier source time does not mean
they arrived before closure. The tracker rejects these old-interval reads.

**Fix:** ordinary departure and timeout drain an in-flight request belonging
to the group's source interval, for at most two seconds from its source time.
After the first absent source frame, only a request captured strictly before
that frame can delay closure. Late completions preserve the departure boundary.
When a new panel appears after the departure span, close the old group even
if its old read remains pending; never include the new panel's rows in it.
The app includes a completed read waiting to be consumed, so a completion
race cannot publish the group early. Replay follows the same policy. Capture
gaps still close immediately and invalidate old requests. A read that misses
the bounded deadline stays rejected. The two-second limit covers the observed
1.35–1.55-second ages at closure, with a 1.6-second delayed-completion regression;
the initial one-second experiment did not. This does not turn one read into two.

Regressions cover delayed confirming Bonus evidence, a stuck request, capture
gaps and an old-interval completion. The diagnostic reading now records
`accepted`, `closedInterval`, `outOfOrder`, `invalidTime` or `nonPanel`.
Rejected reads cannot append pictures to another group's evidence.

## 3. English portal headings fail under Chinese-first OCR

Several empty Portal panels have clear Chinese rows beneath an English
heading, including the last report around 29.70, 225–227 and 440.5–441.5 s.
The last of these visibly contains one L6 Power Cube, one L5 Burster and
one L6 Resonator before its eight-item Bonus panel.

Running the app's accurate, 2× panel OCR at 29.70 s reads the heading at
confidence **0.3** with `zh-Hans,en-US`, below the 0.5 title floor. The
English-first pass reads that heading at **1.0**, but garbles the Chinese
items. Existing title retries all start with CJK languages, and require 0.7.
The failure precedes item parsing: the reader discards the entire panel when
it cannot establish its stage.

**Fix:** add an English-first title-only recovery pass for non-English game
readers. Keep Chinese item OCR, exact item matching and the 0.7 recovery floor.
The heading never changes the game's language, and no title carries across
frames. This adds at most one retry; the successful family is remembered.
A regression reproduces the measured confidences using owned title text;
a masked recorded-item fixture verifies the mixed-language path.

## 4. Presentation highlights start gear waits before actual input

All reports show waits beginning about 0.6 s before input starts. For example,
`18-00-57Z` enqueues hack 1 at video 9.785 s; input begins at 10.385 s and
ends at 16.236 s. A highlighted presentation slot was treated as input, and
its disappearance enqueued the hack. The later actual input exit cannot
replace that early wait because the hack has already been seen.

**Fix:** only input evidence in the tracker's input phase arms a wait. Both
capture and replay pass that phase. The logged presentation-highlight/input
timeline fails before the change and now queues once at actual input exit.
FIFO matching and the existing uncertainty/expiry policy remain in force.

## 5. Fullwidth percent signs discard repeatedly read speed bonuses

In `18-06-56Z`, hack 8's final-stage readings at video 292.291–292.591 s
contain `163%` and `54％`, all five gold contours and `CHAOS`. Hack 12's
final-stage readings at 458.427–458.727 s contain `86%`, `90％`, three gold
contours and `ESCAPE`. The parser reads the hacking values but emits no
speed value because it accepts only the narrow `%`. Earlier narrow-percent
reads explain why the summaries retain provisional speeds 54 and 90.

**Fix:** accept `%` and fullwidth `％` after ASCII digits, in the same
positional fields and with the same label, confidence, final-stage and
two-read requirements. Regressions using the exact strings fail before the
change and confirm final speeds 54 and 90 after it. Other arbitrary OCR
substitutions remain rejected.

## 6. Whole-panel OCR loses red quantities and a clear Chinese item row

The first full replay still left groups 9 and 13 partial in the last report.
Group 9 repeatedly read one L6 Resonator at 316.695–317.945 s, then read its
red quantity as seven at 318.195 and 318.445 s. The tracker correctly withheld
that contradicted row. Group 13 read its one L6 Resonator only at 465.228333
and 466.978333 s, too far apart to confirm; intermediate panel OCR left the
row unread. Both screens visibly show one L6 Resonator.

**Fix:** retry red quantities, unclear quantity colour and unresolved rows in
an isolated physical row crop. A known item/level allows the quantity/name
crop to exclude the icon, rarity bars and coloured L. An unresolved row's
crop retains its L and must establish its own level. The item identity must
match exactly before replacing a known reading, and all quantity digits and
the name remain in the crop. Updated boxes supply the quantity colour. One
retry is allowed per observed row, with the original language and confidence
floor. Both columns of an observed physical row are eligible, because OCR
can omit one column completely. Every recovered item must come from that
column's pixels. For a non-English reader, an additional English-first
quantity/name crop establishes only the numeric marker at confidence 0.5;
item identity and level remain with the game's reader. This prevents the
row retry itself from turning the red `x1` shield at 387.856667 s into `x11`.
It also recovers the omitted Resonator column at 465.478333 s. These two
regressions failed before the final correction. Retries never add a second
source-time vote or borrow a level from another frame. A failed retry keeps
the original evidence.

Two masked exact-frame row regressions failed before the change and now read
one L6 Resonator. Further checks prevent inventing a level absent from the
pixels or carrying an XMP's level into a Resonator. Independently annotated
six-second replays cover these two complete drop groups. The red-quantity
case changes from nine items / partial to ten / complete. The missing-row
case reads all fifteen both before and after in gear-only mode; its failure
depends on the full replay's language state and scheduling, so the short
range alone does not reproduce it.

## Evidence limits and correct partial readings

- The first report's ITO EN name is clipped to `ITO EN Tr…` before the sign.
  It remains unidentified; the recording does not justify inventing a variant.
- Its second drop shows four Portal items, then returns to the map, followed
  by the inventory-overload banner. The video does not show a Bonus panel
  for that group. One-panel coverage is correct.
- The first Bonus panel in `18-03-00Z` is visible at 25.0 s and gone at
  25.2 s. Replay reads all eight Bonus items at 24.905 s, but there is only
  one scheduled source read before departure. These rows stay unconfirmed
  under the two-read rule; successful OCR alone cannot make the group complete.
  Its second group's newly recovered Portal Resonator raises that group from
  six items / partial to seven / complete (visible Portal panel at 49.5 s).
- Three hacks have no result readings. Around their input exits, the recording
  returns to the map or proceeds to another hack. Do not infer game outcomes.
  Two further result pages in `18-03-00Z` are left during their conclusion
  animation, so the retained early results do not establish final outcomes.
- In the last report, group 11's Bonus shield quantities in file order are
  1, 11, 11, then a late 1. The video shows one shield. Mac Vision on the
  video/crop currently reads one, so the original device's 11 is not reproduced
  by those compressed images. Draining the late contradiction prevents a
  confident eleven-shield claim, but cannot manufacture a second confirming
  one-shield read. A regression preserves that uncertainty. This requires a
  device check; the new isolated quantity/name crop also removes the icon/bar
  context implicated by these row failures. There is no parser alias or count
  clamp for eleven.
- Replay uses compressed video frames and fixed simulated OCR latency, not
  the phone's asynchronous completion timings. Replay can therefore read more
  than build 73 even before the fix. Compare before/after replay separately
  from recorded build totals. No population accuracy claim follows from these
  four reports.
- Existing saved readings are unchanged. Raw gear OCR text was not saved and
  cannot be reparsed into old history. These changes need a new build after 73.

## Timing and validation

| Report | Recognition median / p95 / maximum |
| --- | --- |
| 17:53:48 | 10.50 / 23.83 / 38.80 ms |
| 18:00:57 | 9.23 / 14.43 / 77.73 ms |
| 18:03:00 | 12.37 / 23.82 / 54.04 ms |
| 18:06:56 | 19.85 / 36.55 / 143.73 ms |

The last recorder lost 47 pool-full video frames; that is not proof that
recognition lost those same frames. The detector experiment on three decoded
602×1310 frames, 200 iterations each, measured 0.15 ms before and
0.18–0.44 ms after on this Mac. This is a local detector-only measurement,
not on-phone OCR or whole-pipeline performance.

Each language attempt's row recovery is bounded to fourteen physical slots
from observed rows, with one item crop per slot and at most one extra numeric
crop for non-English readers. Completely empty rows do not trigger retries. The extra OCR cost and
the two-second completion bound still need measurement on the tester's phone.
Five warm reads on three exact 602×1310 frames, using the Simplified Chinese
reader linked against the final native debug package, measured median full
panel OCR times of **145, 259 and 235 ms** (maximum **196, 276 and 265 ms**).
These include title/row retries on this Mac under concurrent replay load;
they are not an isolated overhead comparison or a phone timing guarantee.

The four existing annotated gear recordings pass before and after with
quantities **16, 5, 26, 7**. Their four groups are read the same; none reads
more or less. Both existing annotated result recordings also pass with no
annotation failures.

Final checks:

- **396 package tests** in 40 suites pass after the review correction
  (390 before it), using `swift test --build-system
  native`. `make test` hit the known code-signing detritus failure; this is the
  fallback the repository documents for that failure.
- **213 app tests** in 29 suites pass on the iOS 27 iPhone 18 Pro simulator.
- The generic iOS device build passes with signing disabled.
- `scripts/check-ios18-build.sh` passes.
- `git diff --check` passes.

The sanitized `long-gear-annotation.json` and `split-gear-annotation.json`
assert independently checked video quantities and panel coverage. They do
not assert every item identity or FIFO ownership. The recognizer never reads
these annotations. Diagnostic replays of the other two supplied recordings
use empty annotations: their expected-zero group-count failures are not
recognizer errors and are not represented as passing annotated checks.

| Supplied report | Before: groups / complete / quantity | After: groups / complete / quantity |
| --- | --- | --- |
| 17:53:48 | 2 / 1 / 15 | 2 / 1 / 15 |
| 18:00:57 | 4 / 2 / 36 | 3 / 3 / 36 |
| 18:03:00 | 6 / 4 / 57 | 6 / 5 / 58 |
| 18:06:56 | 15 / 10 / 168 | 15 / 14 / 175 |

These are matched Mac replays, not a comparison of phone totals against Mac
totals. All four emit no recognizer failures. The split-panel and long-report
independent count/coverage annotations fail before and pass after. The long
report retains all fourteen Portal/Bonus pairs, plus the ordinary Portal-only
group, matching **175 visible items**. Exact-entry six-second checks for the
three troublesome groups pass at **10, 15 and 16** items with both panels
complete. Final result speeds for hacks 8 and 12 confirm **54 and 90** in the
full replay as well as the exact-string regressions.

## Review correction: preserve departure while draining

The reviewer found a genuine regression in the initial drain implementation:
any pending read since group start could postpone closure, and either new
geometry or a late completion cleared the absence. Two consecutive Portal
panels then shared one slot set, cancelling their conflicting rows.

Permanent regressions reproduce the review's Resonator ×2 followed by XMP
Burster ×5, including a next panel 1.5 seconds after departure. Before the
correction, the pending case merged to one empty group; without a pending
read it kept two groups. Tests also cover requests captured at/after the
departure boundary, a late pre-departure completion, a new interval's
completion, and a brief geometry miss. A single-lane simulation varies one
old request's latency over 0.025, 0.3 and 0.5 seconds, then returns to 25 ms;
each case must retain separate quantities 2 and 5. Subsequent normal reads
still supply two independent votes; the old request is never duplicated.
Running this simulation against a copy of the pre-correction tracker produces
`[2, 5]` at 0.025 s but one empty group (`[0]`) at both 0.3 and 0.5 s.
The corrected tracker produces `[2, 5]` at all three latencies.
The corrected full long-report replay still passes its annotation: fifteen
groups, fourteen complete pairs and 175 items. The four established gear
annotations still pass unchanged at 16, 5, 26 and 7 items. Final validation
after this correction is 396 package tests, 213 app tests, the unsigned device
build, the iOS 18 build and `git diff --check`.

Before committing, both commits were checked in an isolated checkout without
another session's iCloud changes. The percentage-only snapshot passes 377
package tests and 211 app tests; the final gear snapshot passes 396 package
tests and 211 app tests. Both unsigned device builds pass, as does the final
iOS 18 build. The earlier 213-app-test count includes the unrelated iCloud
tests, which remain outside these commits.

## Release gate: measure the shared OCR lane on a phone

The review's performance concern is valid. The current reader retries clear
red rows and unclear-colour rows as well as unread rows. Each language attempt
can add fourteen item crops and fourteen numeric crops. A blank opposite
column can also cost a retry on each read. Fixed simulated latency cannot
measure that cost. This boundary correction leaves that retry policy intact;
retrying only contradictions needs earlier-row evidence with its own lifetime
and regressions, rather than a comparison within one frame.

**Do not release these row retries to production before phone verification.**
The requested beta provides the changes for this field check. Capture a
first-hack-of-the-day panel in Simplified Chinese, including a long all-red
list, and measure actual gear request latency and distinct source reads per
panel on the shared lane. Check the resulting item values against the video,
with two supporting reads spanning at least 0.1 seconds and source gaps no
larger than the existing 0.35-second limit. Check short Portal/Bonus panels,
header/result access to the lane, and late completion at departure. If row
retries prevent confirmation, reduce the retry budget or restrict red-row
recovery to contradictions and rerun the pixel and lifecycle regressions.

Constant 0.3/0.5-second replays test synthetic scheduling and drain behaviour;
they do not satisfy this release gate. At 0.5 seconds, a serial lane cannot
normally obtain two source reads within the 0.35-second agreement limit, so
unconfirmed items are expected and must not be reported as annotation passes.

Full split-panel report comparison, using the same independent annotation:

| Constant OCR latency | Before correction: groups / complete / quantity | After correction: groups / complete / quantity | Annotation result |
| --- | --- | --- | --- |
| 0.025 s | 3 / 3 / 36 | 3 / 3 / 36 | Both pass |
| 0.3 s | 3 / 3 / 36 | 3 / 3 / 36 | Both pass |
| 0.5 s | 3 / 0 / 0 | 3 / 0 / 0 | Both fail quantity/coverage assertions |

There are no recognizer failures in these runs. The 0.5-second annotation
failures are recorded, not waived as passing checks. This recording does not
reproduce the Portal-to-Portal merge; the permanent departure and latency-spike
tests above do. The constant-latency result also shows why phone profiling is
a release gate: returning correct OCR text too slowly can still save no items.
