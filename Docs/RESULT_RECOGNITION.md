# Conclusion recognition, gameplay statistics, and validator reports

Game languages: results, commands and item panels are read in English,
Simplified Chinese and Japanese (checked against recordings) and in
Traditional Chinese and Korean (from translated text only), with the game's
language found automatically; see [GAME_LANGUAGES.md](GAME_LANGUAGES.md).

Status: result recognition, replay/logging, app result cards, and local result
history are implemented. The Statistics tab lists hack results under a
summary card for today, 7 days, or all kept results: hacks, final bonuses, and
per-Glyph acceptance with median drawing time and its timed count. The card
shows each figure's change against yesterday or the 7 days before, in points.
A hack's length follows its portal's level, and so does its time limit, so
bonuses compare fairly only within one length: for Today the card charts the
average Hacking and Speed Bonus for each length played, and it hides bonus
changes while lengths are mixed. For 7 days and All, the card and details
chart per-day averages instead, never single hacks; the player picks which of
Hacking, Speed and Accepted to show, and the choice is kept. Seconds per Glyph (input time over Glyphs, pooled) compares
across lengths: input time runs from the first to the last frame showing the
input screen before the result appears, saved as `inputSeconds` from this
version on. The details chart both bonuses and the accepted share over time,
hacks per hour or day, the weakest Glyphs and drawing times, ranking only
Glyphs with at least three attempts, and a "By hack length" table lists each
length and, under a length several levels share (3 and 4 Glyphs), each level
the gear test read. A "By command" section compares bonuses by presentation
speed and gear per hack by key command (see COMMAND_RECOGNITION.md). With logs
on, testers also see reading accuracy. Wherever
gear was read in the period, as on each hack's card, the card and details show
gear totals: one row per item, split into level or rarity chips (L? for an
unread level), with multiplied drops and a note when some hacks' gear wasn't
fully read.
Drawing time comes from the judged validator attempt, from its first-ink frame
to the frame proving its lift, so final slots are never timed. Attempt and
redraw counts, pauses, and the separate InputAttemptTracker remain planned.
PiP/Island result summaries and the issue-report flow also remain planned.
The setup and Statistics screens offer result reading; persistence is a separate
choice, independent of diagnostic logging. On-phone PiP lifecycle checks and a
wrong-last-Glyph recording remain release evidence gaps. Companion to
INPUT_VALIDATION.md; milestones below describe the full target scope.

## Player experience

After a hack, read the game's conclusion and show:

- Each slot's game result: accepted, rejected, or unreadable.
- The expected Glyph, when known, so a rejected slot can show what to draw.
- The final Hacking Bonus and Speed Bonus, as displayed by the game.
- Any disagreement between the game result and our input check.
- Drawing time and observed attempt count for each slot, including redraws.
- A hack summary of drawing time, pauses, redraws, and game-confirmed outcomes.

Selected display: a compact result summary in PiP / the Island, with
full details and reporting in the app. Result recognition and session statistics
work with logging off too. Selected history behavior: save small local gameplay
summaries between sessions independently of debug logs, with a separate
"Save gameplay history" preference and an option to clear saved history.
Saving and exporting diagnostic evidence uses the existing Save logs and
screenshots setting; video remains a separate option. No automatic sending.

The result display explicitly says it comes from the game. It supersedes the
drawing-time mark on screen, while the original validator result stays in the
record for comparison. An unreadable game result must not erase a known input
check or be displayed as a rejection. A new hack replaces the compact summary;
completed summaries remain in local gameplay history when that preference is
on, whether or not debug logging is enabled. Diagnostic session reports are a
separate evidence store.

## What the current capture establishes

Sources: `DynamicGlyph-spikeB-2026-09-23T23-00-56Z.zip`, specifically
`screen-recording.mp4`, `recognition.jsonl`, `tracking.jsonl`,
`input-validation.jsonl`, and `snapshots.jsonl`. Video annotations use frames
extracted at 20 Hz; log times below use `elapsed` or source timestamps relative
to `recording.json:firstPresentationTime`. These are screen observations, not
instrumented touch events. Raw device evidence remains local.

The recording presents `truth, idea, discover, xm`. Its annotated timeline is:

| Time | Observed screen |
|---|---|
| 31.50 | Last input frame |
| 31.55–32.35 | Hacking Bonus / Speed Bonus labels, values not yet shown |
| 32.40–32.75 | TRUTH, Hacking Bonus 30% |
| 32.80–33.15 | IDEA, Hacking Bonus 60% |
| 33.20–33.55 | DISCOVER, Hacking Bonus 90% |
| 33.60–34.00 | XM, final Hacking Bonus **120%**, Speed Bonus **55%** |
| 34.05 | Portal / item-drop screen |

The movie frame at 33.85 seconds shows the final pair. It is annotation ground
truth, including the fact that Hacking Bonus exceeds 100%.
The final stage lasts only about 0.45 seconds, comparable to intermediate
stages; there is no additional observed end-of-animation signal to wait for.
The labels appear about 0.85 seconds before the first value and are an early
result-detection cue. Names appear only during their own roughly 0.4-second
stage; previously revealed hexagons remain lit.

The human interpretation is that the final drawings were accepted. The capture
alone does not establish a classifier distinguishing acceptance from rejection:
a rejected slot might also light up. Keep acceptance annotations separate from
live machine claims until both outcome classes have been recorded. The new
five-Glyph capture below provides the contrasting intermediate-slot example.

The input log contains attempts 1/TRUTH, 2/IDEA, 3/TRUTH, 4/IDEA, 5/DISCOVER;
XM has no validator attempt because it is the final slot. The recognition log
first shows zero-based highlight 2 at **25.26 s**, 1 at 25.66 s, then 0 at
25.91 s. The 25.31-second sample is a subsequent observation, not the first
boundary timestamp.

| Movie time | Redo appearance | Highlight context from the log |
|---|---|---|
| 25.45 | Normal | 2 |
| Approximately 25.50–25.70 | First bright pulse | 2 → 1 at 25.66 |
| Between pulses, normal by 25.80 | Pulse fades / normal | 1 |
| Approximately 25.85–26.05 | Second bright pulse | 1 → 0 at 25.91 |
| From about 26.10 | Dimming, apparently disabled | 0 |

Annotate **two apparent Redo presses, one slot backward per press**, assuming
the bright pulses are button press feedback. The disabled appearance is an
observation, not proof of disabled interaction. This annotation combines the
button and highlight evidence; highlight motion alone cannot count presses.
The button is covered in other captures, including IMG_2003.MP4, so this is
annotation evidence, not a required live signal or a general reset rule.
The final TRUTH and IDEA outcomes belong to attempts 3 and 4, never 1 and 2.
The user's statement that both TRUTH drawings were correct remains separate
evidence about the superseded drawing.

Replaying `input-validation.jsonl` edge coverage with `recognition.jsonl`
context and original timestamps through the validator at `02f75f9` yields
`unavailable / partialEdge` for attempts 1 and 3; attempts 2, 4, and 5 match.
This checks validator comparison input, not pixel/OCR recognition of the
conclusion, and differs from resampling the encoded video at 20 Hz.

Current header OCR searches a narrow top crop for phrases such as "Glyph hack
complete". In this capture the tracker instead became interrupted. Conclusion
recognition must inspect the result panel independently of that header and of
the drawing lattice calibration; it cannot wait for tracker.state == completed.

### Five-Glyph deliberate error and Redo

Source: `5Glyphwitherrorglyphandredo.zip`, session
`spikeB-2026-09-24T00-01-28Z`, its `screen-recording.mp4`, `recognition.jsonl`,
`tracking.jsonl`, and `input-validation.jsonl`. The user annotates **one wrong
drawing and one Redo**. Sequence: **OLD, NATURE, LESS, STRONG, NOW**.

At about 24.0 s the panel labels appear without values. OLD, NATURE, and LESS
then raise the displayed Hacking Bonus to 10%, 20%, and 30%. During STRONG's
stage its lower hexagon contour becomes **magenta**, while the bonus remains
30%. NOW's contour becomes gold and the final pair is **40% / 0%**, visible in
the movie frame at 26.30 s. The panel departs at about 26.6 s. Earlier accepted
slots retain gold contours. The PiP covers the upper row but leaves its lower
V contours and the stage name visible. The classifier samples both lower
slopes, not fireworks or the overlay's own Glyph diagrams.

The highlight first advances to slot 2 at 16.581 s, then returns to slot 1 at
16.981 s. NATURE's first validator attempt (2) is superseded by attempt **3**.
Final comparisons use **1/OLD, 3/NATURE, 4/LESS, 5/STRONG**; NOW has no input
validator attempt because the last slot remains outside its scope. The game
rejects STRONG, agreeing with the validator's `differs` verdict. The other
compared final attempts match. Press count here is the user's annotation;
backward highlights alone remain insufficient to infer button presses.

This supplies both gold/correct and magenta/incorrect examples for diagnostic
classification in the measured layout. It does **not** supply a rejected last
slot, another language, or another result layout. The app now displays the
classified outcomes, while the missing last-slot example remains a release
validation gap. Logs distinguish raw appearance, classified outcomes, and
unknown fields.
Sanitized region fixtures are in
`Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/Assets/Screenshots/Results/`
(the private test-assets submodule) and separate human assertions in
`Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/Results/`.

### M1 implementation and replay

- `ResultScreenReader` uses one English OCR crop for labels, values, and stage
  name, plus lower-contour colour samples. `ResultTextParser` requires both
  labels and positional percentage fields. Both `%` and Vision's fullwidth
  `％` are accepted after ASCII digits; other text stays unread. Missing text
  is never zero.
- A value line ending in `%` that holds anything but ASCII digits, where no
  value was read, gets one second look at the same crop enlarged 1.5 times;
  only the panel's lines are taken from it. At capture size Vision read a
  one-Glyph result's 38% as `З8%` (a Cyrillic Ze) on every frame of the
  2026-10-05 field test. Enlarging every read instead lost short stage names
  such as XM, so the stage name is always read at capture size.
- One Glyph's lower contour sits at the centre, where three Glyphs' spacing
  puts a lone hexagon (`one-final.png`). Two Glyphs are still unrecorded.
- `HackResultTracker` requires two independent agreeing source reads spanning
  at least **100 ms** in the final stage to confirm each bonus independently.
  The stage can be identified by its attributable name or a gold/magenta last
  contour; a name identifying an earlier slot contradicts that contour cue.
  There is no additional settling delay before counting value agreement.
  Synthetic tests cover one-/two-frame (20 Hz) value lag, without establishing
  a guarantee for longer unrecorded lags. Repeated or covered names can use a
  readable final contour; when both cues are unavailable, finality stays unknown.
- `ResultObservationSession` owns one hack at a time independently of the
  presentation phase. `ValidatorResultComparison` preserves existing attempt
  IDs, invalidates associations on verified backwards moves and uncertain
  continuity, and never rewrites validator results. The last slot has an
  unknown association, not a fabricated attempt or a disagreement. A banner
  covering the entire strip is reported as occlusion, not absent indicators.
  Current input-header evidence also prevents an empty-strip timeout; stale
  header readings expire under the presentation tracker's freshness policy.
- `HackResults` accepts each hack's first closed summary once. Its identity
  remains remembered for the app run after Clear or memory-log eviction, so
  retirement/late callbacks cannot restore deleted results, reopen a closed
  hack, or apply a later persistence preference to an earlier unkept hack.
  A hack still open when results are cleared can finish and be saved normally.
- `GameHeaderReader` coordinates one global OCR request and one completed result
  awaiting consumption. Normal header cadence/maximum age stay 100/350 ms.
  Late completions cannot repopulate a retired session. Result cadence uses a
  2 ms timestamp tolerance, with measured latency and pressure drops in logs.
- Optional `results.jsonl` records raw text/boxes, appearances, summaries,
  comparisons, and evidence drops. `result-frames.jsonl` records saved/failed
  cropped JPEGs, source dimensions and crop coordinates. Evidence has its own
  5 Hz/2.5 s numeric-stage budget, two ordinary writer slots, and two reserved
  decision slots. Decision changes also save the preceding supporting read.
  The existing session archive includes these files. Logging off creates none.
- `glyph-replay --results live` is the default shared cadence; `exhaustive`
  inspects every candidate and `off` retains legacy every-frame header OCR.
  `--ocr-latency` models completion delay, not measured phone performance.
  `Tools/check-result-replay.py` decodes original frames/timestamps and compares
  the output with a human assertion JSON without passing annotations into
  recognition. It reports missing associations/coverage separately from errors.

Example (use the corresponding original movie and private local path):

```sh
python3 Tools/check-result-replay.py <screen-recording.mp4> \
  Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/Results/five-annotation.json \
  --replay Packages/GlyphRecognition/.build/release/glyph-replay \
  --output /tmp/five-result-replay.json
```

## Recognition rules

1. Detect the conclusion using a combination of result-panel geometry and its
   labels, not a percentage or glowing hexagon alone. Start looking during the
   current hack's input and briefly after interruption. Bind source frames to
   that hack before asynchronous analysis begins.
2. Read the result row with a dedicated reader. Its layout and animation differ
   from the drawing-time highlight. Associate outcomes by slot position and
   verified slot count; use the displayed name as corroboration, not as the
   slot identity, because a sequence can repeat a Glyph. Track **stage/revealed**
   separately from **lit/colour/appearance**: revealed means this slot's turn
   in the result animation has arrived, established by an attributable name or
   a verified stage transition. It does not require illumination, a bonus
   increase, or an accepted result. A name alone cannot index repeated Glyphs.
   If stage identity cannot be verified, it remains unknown.
3. Require repeated independent source-frame evidence for acceptance or
   rejection. A hidden or not-yet-animated slot stays unreadable. Darkness is
   not itself a rejection cue; classify appearance only with validated evidence.
   Both acceptance and rejection cues must be established from annotated
   correct and deliberate-error recordings before enabling either automatic
   correctness claim. Until then, log neutral visual observations such as
   stage identity and lit/colour independently, and evaluate comparisons against
   human annotations only. Never infer correctness from stage arrival or bonus.
4. OCR Hacking Bonus and Speed Bonus within their separately labelled regions.
   Keep missing/unreadable values distinct from a genuine 0%. Read displayed
   values rather than calculating them from time or assumed scoring formulas.
   Do not assume Hacking Bonus is capped at 100%.
5. Keep candidate readings separate from final values. For the verified layout,
   a field becomes final after the **last expected result slot is verified as
   revealed, regardless of its outcome or illumination**, and at least **two
   independent source-frame reads agree** on its value, initially at least
   100 ms apart. This is a reveal-stage check, not
   an acceptance claim; slot count comes from this hack's verified sequence.
   It must work inside the final 0.45-second stage. Subsequent observed panel
   departure corroborates the end; it does not downgrade an established final
   field to partial. Conflicting reads reopen that field as uncertain.
   A plateau alone is not final, nor does panel disappearance prove the last
   visible value was final if the final-stage cue was missed. When the last
   slot is obscured, retain labelled last-observed bonus readings and unknown
   finality, unless a separate terminal cue has been validated. Missing or
   disagreeing fields stay partial independently.
6. Treat PiP overlap, notifications, conflicting OCR, frame gaps, unsupported
   layouts, and capture interruption as uncertainty. Preserve independently
   established fields without inventing missing ones. Never inspect our own
   overlay as though it were the game's result row.

### Coverage and recognition scheduling

Measure result-row/name visibility under the actual PiP placements in the
15:07/15:08 and 23:00:56 captures before choosing crop coordinates. The conclusion
row uses a different position from the input strip and can lie under a window
that previously left input indicators readable. Record visibility per region
and the fraction of each short reveal stage that remains usable. Distinguish
the overlaid app diagrams from the game's row.

When the row/name is covered but the central panel is readable, the compact UI
falls back to bonuses only. It may show final values only if finality was
established; otherwise label them as observed values / result incomplete.
Do not infer correctness, final stage, or last-slot identity from the amount.
Glyph names corroborate position when visible; their short lifetime must not
make capturing every name a mandatory condition for reading the bonus panel.

Use **one OCR coordinator with one request in flight globally**. Reuse the
header reader's scheduling mechanism, switching between header and result crops.
A cheap visual panel candidate (or observed input exit) schedules result-label
OCR; confirmation switches the OCR budget to results until exit. Do not rely on
header `.completed` to trigger it. Probe the result region on candidates while
still in input, so the 0.85-second label-only lead-in is available. If a candidate
is rejected, resume header mode; fresh next-hack cues retire result work.

Initially cap OCR at 10 requests/second across both modes, newest frame wins,
with no unbounded queue. One result request can read the separate relevant
regions within its chosen crop. Tag mode, session, hack, and source time at
submission; reject obsolete results and count only distinct source frames.
Measure result-crop latency and successful reads per 0.4-second reveal on the
phone. If fewer than two usable reads arrive, return partial rather than borrow
cached reads or run a second parallel OCR pipeline. Replay supports this same
cadence/drop policy as well as exhaustive offline analysis.

Replacing GameHeaderReader's scheduler changes a phase-detection dependency,
not just result recognition. Preserve its normal header-mode 10-Hz scheduling,
source-age rules, and phase outcomes when there is no result candidate. Make
candidate probing bounded: at most one result probe before returning to header
mode on rejection; measure the resulting header-read gap. Do not repeatedly
steal header requests for a persistent false candidate. Retain the original
header strategy behind a replay comparison switch until parity is demonstrated.

M1 must pass the phase fixtures and `Tools/check-phase-replay.py` on the existing
annotated recordings, plus a live-cadence scheduler replay with false panel
candidates during presentation/input. Compare header submission cadence,
source-age/dropped-read metrics, phase transitions, confirmed sequence, and
input guidance with the baseline. A synchronous every-frame OCR replay alone
cannot establish scheduling parity. No lost or spurious transitions are allowed;
only explicitly specified conclusion handling may change the completion path.
If the coordinator cannot meet this gate, keep result recognition in offline
replay/log experiments until scheduling is fixed.

The first supported game layout is the English portrait layout in the supplied
recordings. App UI strings are localized into all supported languages; that
does not imply other game-language layouts have been verified.

## Early Done and absent conclusions

The player reports that pressing Done early may leave input without showing a
conclusion page. Observing a conclusion is optional, not required to close a hack
or retain its gameplay statistics. Include this case in the recording annotations.

Keep the input lifecycle separate from result availability. Result availability
can be awaiting, partial, complete, or not observed. After an observed input
exit, allow a bounded result-observation window, with its duration established
from recordings. A new hack or capture stop closes that window immediately;
late OCR must not attach to the next hack. If the window expires, archive the
hack with "No conclusion observed", preserving any fields already verified.
Do not leave the UI waiting forever or keep "draw this now" guidance alive.

- Preserve observed attempts, redraws, and measurable durations in history,
  even when the player submits no Glyphs or only part of the sequence.
- Unknown game outcomes and bonuses stay unknown, not rejected or 0%. No
  automatic validator disagreement or acceptance-rate contribution is possible
  without the corresponding game outcome. Manual issue reporting remains
  available when evidence was saved.
- Report "Ended early" only with a verified early-exit cue. A visible Done
  button alone does not prove a press; loss of frames or the result panel might
  also explain the missing conclusion. Store the observed exit evidence and
  distinguish it from capture interruption and unknown termination.
- Do not treat unobserved slots as zero-duration attempts. A drawing with no
  proven lift keeps an incomplete duration even if an exit follows it. Input
  elapsed time needs observed phase boundaries; retain only a labelled partial
  interval if capture ends first.
- Count hacks with no observed conclusion separately from scored hacks in
  session/history summaries. The compact overlay can say "Session ended ·
  result unavailable"; the app shows the available attempt data and reason.

## Matching the game result to our check

Store identity as capture session + hack + slot + attempt. Retain every issued
validator verdict and withdrawal, and separately track which attempt remains
submitted after backward moves / Redo. A completed game result attaches only
to a provably final attempt. Ambiguous resets or missed boundaries leave this
association unknown; do not fall back to the last verdict for that slot.

| Game result | Final attempt's input check | Comparison |
|---|---|---|
| Accepted | Differs | Possible false warning |
| Rejected | Matches | Possible false match |
| Accepted | Matches | Agreement |
| Rejected | Differs | Agreement |
| Known | Unable to check / no check | Coverage gap, not a validator contradiction |
| Unreadable or attempt identity unknown | Any | Cannot compare |

The last slot can have a game result even though v1 input validation does not
check it. Keep that distinction in the UI and metrics. If a warning was later
withdrawn, preserve that history for manual reporting; do not count it as a
final disagreement. Predictions and inferred expectations do not become
confirmed presentation observations because the game result arrived.

## Gameplay statistics

The app observes screen frames, not finger events. Label drawing durations as
estimated and show seconds to one decimal place. Keep source timestamps and
boundary uncertainty internally; a missing boundary is unknown, not zero.

| Metric | Definition |
|---|---|
| Drawing time per attempt | First observed new ink to the observed lift boundary, excluding the post-lift comparison window |
| Attempts per slot | Distinct observed starts on that slot, with each attempt retained even if later superseded by Redo |
| Redraws | Observed subsequent attempts on the same slot; a backward highlight alone does not count as a drawing or a button press |
| Pause between attempts | Prior observed lift to the next observed new ink; includes the player's wait before redrawing |
| Measured drawing time | Sum of measured attempt durations, including superseded attempts; report measurable count and final-slot omissions, not an unqualified total |
| Input-phase elapsed time | Observed entry into input to observed game completion; includes thinking and pauses and is not a precise last-finger-lift time |
| Final acceptance rate | Game-accepted slots divided by slots with known final game results; show the denominator and unreadable count |

Per-slot details show attempt 1, attempt 2, and so on, their durations and status
(submitted, superseded, cancelled/cleared, or incomplete), followed by the final
game outcome. Drawing twice does not mean the first attempt was incorrect.
The game result remains attached only to the provably final submitted attempt.
Count a cancelled drawing when its start is proven, but do not count bare clears,
highlight flickers, OCR retries, or validator restarts as fresh drawings.

At hack level, show attempts and redraws, measured drawing time, input elapsed
time, pauses, final slot outcomes, and both bonuses. Keep the compact overlay
focused on game results/bonuses; the app holds the attempt breakdown. Do not
compute a Speed Bonus from these timings or present it as a timing measurement.

For session/history summaries, group attempts by confirmed expected Glyph,
without merging repeated occurrences within a sequence. Show observed drawings,
redraws, median measured drawing time with its sample count, and game acceptance
rate for known final submissions. Keep unknown/predicted Glyph identities out
of named-Glyph aggregates. Superseded attempts contribute to drawing-time and
attempt statistics, but not to the game's final acceptance denominator.

### Timing and counting boundaries

- Track first new ink separately from the preceding clear. The validator's
  current `startTime` is the last clear sample, so subtracting it from `liftTime`
  would include sampling delay and is not the proposed drawing-time metric.
  An edge-free touch-down can already contain new ink; record that frame when
  it qualifies as a verified new-start boundary rather than waiting for an edge.
- For non-final slots, use the first highlight-advance frame after its second
  agreeing sample confirms the lift. Keep the previous/current frame times as
  the boundary interval rather than timing from confirmation or verdict delivery.
- Observe starts for the last slot too. Its exact lift is not established by
  the current validator. Until a separate end cue is validated in recordings,
  count a proven start but leave measured duration unavailable. When an observed
  conclusion demonstrably follows that attempt's submission with uninterrupted
  capture, optionally show a separate **upper bound** (illustrative UI text:
  "≤ 1.2 s", not a measurement from this capture). Compute
  it from the earliest supported start boundary to the source time of the first
  panel frame, rounded upward, not OCR arrival. No bound is justified for an
  ambiguous early Done/cancel path. Keep bounds out of measured totals/medians.
- A gap, covered strip, missing start, or ambiguous reset can make counts
  incomplete. Show "at least N observed attempts" where appropriate, and no
  redraw count when attempts cannot be assigned to a slot reliably. Do not
  turn fragmented observations of one stroke into several attempts.
- A verified backward move invalidates final-submission associations for the
  affected suffix, but preserves historical attempts and their measured time.
  Only new observed drawing starts increase attempt/redraw counts.
- Exclude interrupted durations from exact duration aggregates. Show coverage
  explicitly, for example "Timing available for 4 of 5 observed attempts".
  Label the sum "Measured drawing time", not an unqualified total when data is
  missing. Show final-slot omissions separately: "4/5 attempts timed; final
  slot excluded". Per-Glyph medians must also expose timed count and final-slot
  omissions; sequence endings are not random, so this is a systematic bias,
  not just occasional missing data. Keep complete and partial hacks distinct;
  unknown is never failure.

### Ownership and storage

In M3, build a framework-free `InputAttemptTracker` as a **separate observer**
on the same frame inputs, not an early extraction from PlayerInputValidator.
It observes every reliably indexed slot, including final/unconfirmed slots.
The validator omits those slots and restarts/discards attempts on interruptions;
its result count or `nextAttemptID` cannot serve as gameplay statistics.

Replay compares observer boundaries and associations with the validator's
started/lifted/finished events on eligible slots, with explicit reasons for
intentional differences (clear versus first-ink time, final slots, interruptions).
Use a separate observer ID namespace and a verified mapping to existing
validator attempt IDs. Ambiguous mappings stay unknown. Keep the validator's
current IDs and behavior unchanged in M1–M3. A later shared-boundary refactor is
optional and requires demonstrated parity across recordings and regressions;
changing attempt-ID meaning requires a log schema bump and migration/reader
compatibility, not silent reassignment of historical results.

Use the selected separate "Save gameplay history" preference for structured
summaries, enabled by default. It saves no screen images, video,
raw OCR, or location. Include schema/policy version and quality/coverage fields,
and support clearing history. With history off, keep session summaries in
memory; debug-log retention remains independently controlled. Logging off must
not imply that statistics recording is off when history is explicitly enabled.
Detailed evidence is still required for a reproducible validator bug report;
a statistics summary alone is not a substitute.

Initial history retention: keep at most **1,000 hacks or 90 days**, whichever
limit removes an entry first. Prune on load and after writes, and recompute
aggregates from retained summaries; label them as retained history, not lifetime
statistics. State the retention policy beside the preference. Diagnostic session
folders retain their own deletion rules and are not pruned by history retention.
Use versioned records and atomic writes; test supported schema migrations,
missing fields, and interrupted writes. Preserve unsupported/corrupt records
without silently interpreting or overwriting them, and offer a confirmed reset.
A separate history-export feature is out of scope; diagnostic report sharing
remains the existing export path.
Optional iCloud sync mirrors the saved results and gear readings to the
player's private CloudKit database, off by default and switched in Result
options. It applies at once by reopening the store. Panel pictures stay in the
session folder of the iPhone that took them. The syncable schema (V3) has no
unique attributes and a default for every attribute, as CloudKit requires.
The store keeps keys unique itself, reads past a duplicate, and removes it at
the next prune or save. Retention and Clear delete rows one by one, never in a
batch, so the deletions reach the player's other iPhones. Clearing while
syncing says it clears every iPhone. The configuration is never `.automatic`,
which would sync whenever the entitlement exists.
Result options show the sync's state from the store's CloudKit events
(`NSPersistentCloudKitContainer.eventChangedNotification`, which SwiftData
stores post too): setting up, syncing, the time of the last success, or why it
stopped. A failed export arrives as a partial failure holding each record's
error; any `quotaExceeded` among them means the player's iCloud storage is
full, since the private database counts against it. Not signed in, offline and
busy (with CloudKit's retry time) are told apart; anything else shows its
CloudKit code. A failure stays shown until a later sync succeeds, and the
Statistics page summary then says sync is paused. The account status from
`CKContainer.accountStatus()` still comes first.
Pulling down on the Statistics page rereads the saved results once any running
sync step ends, or after 20 seconds. CloudKit has no call that asks for a sync,
and the store stays open. It imports by itself when it opens and when iCloud
pushes another iPhone's changes. An earlier build reopened the store on each
pull. That cancelled the steps in flight (Core Data error 134407, the store
was removed) and set mirroring up again, so only the switch reopens it now.
A setup that succeeds is not shown as synced: only a finished import or export
is. A step cancelled by switching sync neither fails the status nor holds it up.
Historical policy versions remain attached to records; do not silently rescore
old checks under new recognition rules. Clearing history also clears its cached
aggregates, while "delete session report" affects the separate diagnostic store.

## Reporting flow

When logs were enabled for the hack, its app result card and saved report offer
"Report a recognition problem". The user can select a slot, bonus, or timing/count field,
choose what was wrong, and add an optional note. Preselect a detected
disagreement, but allow reporting when our conclusion reader itself is wrong.
User corrections are annotations; they never silently overwrite machine evidence.

Allow marking a problem while capture continues. For v1, exporting uses the
existing stopped-session share flow: stop capture, review the report, then open
the iOS share sheet. Keep automatic disagreements as local review candidates,
not submissions. With logging off, explain that evidence was not saved; enabling
logs applies to a future session and cannot recover the past hack.

Add to the session archive:

- A versioned result event log and per-hack summary with field status, raw OCR,
  bounding boxes, source timestamps, final-attempt links, and disagreements.
- Existing presentation/input-validation logs, including partial-edge support.
- Attempt boundary events, supersession history, estimated duration intervals,
  and statistics coverage, so an incorrect timing or attempt count can be traced.
- App build, validator/result-reader policy versions and parameters, capture
  geometry, and supported layout identifier.
- User-selected issue, claimed correction, note, and evidence references.
- Result frames and relevant input frames; video only if already enabled.

Current snapshots depend on drawing-recognition changes and miss the result
animation: `recognition.jsonl` and `snapshots.jsonl` identify only samples 615,
665, and 669 saved between 31.4 and 34.4 seconds, at about 31.56, 34.10, and
34.30 seconds. None captures the numeric stages. Their `encodingMilliseconds`
values are 60.3, 74.6, and 89.7 ms; all saved PNGs in this session span
56.8–188.0 ms. Do not add full-frame PNG at 20 Hz.

Reserve a separate evidence budget: start with one label-only detection frame,
then about **5 cropped/JPEG frames per second for 2.5 seconds from the first
numeric/reveal stage** (about 13 frames), plus frames used for terminal decisions.
Do not start that 2.5-second budget at the first label and exhaust it before the
final stage. Adapt the bounded duration for longer sequences based on recordings;
log budget exhaustion explicitly. Store crop coordinates and source dimensions.
Reuse selected OCR frames for evidence where possible; bound the asynchronous
writer queue/bytes and record drops or failed saves. Reserve decision-frame
capacity instead of promising every candidate frame can be saved. Finalize writes
before export. With logs on and video off, the report must contain numeric stages
and terminal evidence, or explicitly identify the missing evidence.

## Independently shippable milestones

### M1 — Result reader, logs, and replay comparisons

- Add framework-free ResultFrameEvidence, HackResultTracker, and
  ValidatorResultComparison, plus the shared pixel/OCR result reader and single
  OCR coordinator. Integrate result detection independently of lattice/header
  success. The established input validator is unchanged.
- Annotate/replay the conclusion timeline, attempt mapping, occlusion, early
  Done, and deliberate errors, explicitly including a wrong last Glyph. Record
  how its stage is identified and whether illumination/bonus changes occur;
  test absence of either synthetically without assuming the game's behavior.
  Use original frame timestamps; record sampling mode and test the bounded
  live OCR schedule, not just every-frame replay.
- Save neutral slot observations, bonus candidates/finality, source evidence,
  and comparisons. Initially compare to human correctness annotations. Enable
  automatic accepted/rejected claims and live comparisons only once recorded
  counterexamples establish both classes. That gate need not block bonus logs.
- Map final attempts using existing validator events and verified backward
  transitions; unknown mappings remain unknown. No InputAttemptTracker refactor.
- Ship when 120%/55% finality and evidence retention pass the annotated capture,
  and ambiguous/covered exits produce partial results without fabricated claims.
  The existing phase fixtures, `Tools/check-phase-replay.py`, and the bounded
  scheduler parity checks above are mandatory M1 gates, since the shared OCR
  coordinator changes the live header path even though the validator is untouched.

### M2 — Compact result display and app result details

- Carry independent result state/revision through GlyphDisplaySnapshot, PiP's
  render key, and Activity content/semantic key. Use a bonus-only fallback when
  slot outcomes are unavailable, including while the correctness gate is closed.
- Route validated panel detection through explicit phase evidence to end input
  guidance without rewriting the remembered sequence. Keep any confirmed final
  summary after panel departure; a new hack takes display priority.
- Make the transition to a final result a priority semantic change, scheduling
  one update as soon as any in-flight Activity update finishes. Ordinary
  waiting/interrupted snapshots must not replace that pending final result for
  the same hack. Preserve single-update-in-flight ordering; a newer hack may
  supersede the old result. Do not carry the input-guidance expiry onto results.
  Test a final result arriving about 2.5 seconds after input ends, including
  panel departure before send completion. This guarantees a submission attempt,
  not when iOS will visibly refresh the Island.
- Localize and device-test PiP/Island/app summaries. This milestone is usable
  without statistics or the new report form; existing archive sharing remains.

### M3 — Attempt observer and gameplay statistics

- Add InputAttemptTracker alongside the validator; compare boundaries in replay
  before using the observer for statistics. Preserve old validator identities.
- Implement per-attempt duration/counts, pauses, redraws, measured aggregates,
  optional final-slot upper bounds, and explicit positional coverage bias.
- Ship in-memory session statistics and app details independently of persistent
  history. Timing failures must not change correctness, prediction, or results.

### M4 — Persistent history and issue reports

- Add the selected default-on local statistics history, retention/migrations,
  deletion, and aggregates independent of diagnostic logging.
- Add the result/timing issue form, user annotations, evidence preview, and
  enriched export using existing SessionReportStore mechanisms. Marking can
  happen during capture; exporting still uses the stopped-session share flow.
- Verify all history/logging on/off combinations, logs without video, old
  reports, retention, migration, write failures, and report cancellation.

Each milestone runs the relevant full package/app suites and iPhone build, plus
annotated replay and phone checks for its changed surfaces. Keep unresolved
correctness/detection gates explicit; shipping a milestone must not imply that
all later analytics or report features exist.

## Acceptance checks

- Annotation-level comparison: final TRUTH belongs to attempt 3 and IDEA to
  attempt 4, never attempts 1/2. Archived TRUTH `differs` conflicts with the human
  acceptance annotation; current attempts 1/3 are `partialEdge`, and final
  attempt 3 is a coverage gap. Automatic acceptance remains gated on both
  correct and deliberate-error visual examples, including the final-slot cue.
- At the recorded cadence, two agreeing reads in the final-slot stage establish
  **120% Hacking Bonus / 55% Speed Bonus** within its approximately 0.45 seconds.
  Intermediate 30/60/90% readings never become final. Panel departure retains
  finals. Test zero fields independently and obscure the final-stage cue to
  require labelled observed values with unknown finality.
- Test a rejected final Glyph: its result stage can arrive with no lit hexagon
  and no bonus increase. Verify stage completion/finality independently of
  correctness, or keep stage unknown when its evidence is absent. Collect a
  deliberate-error recording for this case before enabling outcome claims.
- Synthetic timing tests delay the bonus value by one and two 20-Hz frames
  after the final name/stage appears. Early old-value reads remain candidates;
  they must not finalize the preceding stage's bonus. Also test an unchanged
  final bonus after a rejected last Glyph, so "must increase" cannot become
  the workaround. The real capture changes name and value on the same sampled
  frame; it does not establish a general no-lag guarantee. These are M1 tests,
  not evidence that a real lag has already been recorded.
- Correct and deliberately incorrect drawings produce the expected game-result
  readings, with slot identity maintained for repeated Glyphs and Redo.
- Partial/covered conclusions, missed animations, early dismissal, unsupported
  layouts, and stale callbacks produce unknown fields without false rejections
  or cross-hack association. Next-hack guidance replaces the prior summary.
- Early Done with no conclusion archives an unscored hack with the attempts
  observed so far. It produces no assumed rejection, bonus, or disagreement.
  Also test zero attempts, capture stop during the wait, a new hack before the
  timeout, and delayed OCR from the retired hack.
- Logging off writes no result evidence; logs on with video off still yields
  a useful report. Marking while active, stopping, save failures, sharing,
  cancellation, old reports without these files, and deletion are covered.
- The attempt ledger covers final/unconfirmed slots, repeated Glyphs, Redo,
  clearing without submitting, missed starts, gaps, and resumed observations.
  Reprocessing or repeated delivery of the same frame never increases counts.
- Drawing duration excludes pauses, debounce delay, and post-lift validation
  time. An unobserved final-slot lift has no measured duration; any justified
  upper bound stays separate. Aggregates expose positional coverage/bias and
  never score superseded attempts from final results.
- Test history and diagnostic logging independently in all four on/off
  combinations; summaries contain no screenshots/video and old reports remain
  readable. History deletion, capture restart, and partial sessions are covered.
- Replay reports field accuracy, unknown rates, attempt-association failures,
  and validator disagreements separately. Do not count unknowns as correct or
  compare superseded attempts with the final game's result.

The implemented reader is the basis for the remaining milestones. Both automatic
acceptance and rejection require validated distinguishing cues. Final bonus claims follow the explicit last-slot
reveal rule; missed final-stage evidence stays partial rather than being filled
with a timing guess.
