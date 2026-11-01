# Command recognition and gear statistics

Status: M1 and M2 implemented: replay (`--commands`, `Tools/check-command-replay.py`)
and live capture read the notices, save them with each hack, and show them on
its card. M3's first version is in the Statistics details: "By command" shows
bonuses and accepted share by presentation speed, and keys and other items per
hack by key command, counting only hacks whose gear was read in full with no
multiplied drop and showing them as measured of all. Drone hacks and
uncertain or unseen commands have rows of their own; older history without
commands is left out. Portal mode is not yet detected
positively, so a hack that isn't a drone stays unknown. Based on the current
code, the two 2026-09-28 recordings, and the player's rules. This feature
records the game's acknowledgement of a command, not a guess about the drawn
shape.

As built, after the peer review below: an unseen or unbound command window is
uncertain, never "no command"; a frame gap, a dropped frame or leaving the
Glyph screen for more than 0.5 s makes both settings uncertain, and 2 s away
cancels the window; an unreadable read beside clear ones is ignored; the
second sample of a notice waits 45 ms for a settled frame; notice OCR yields
to the header while a hack is presented or drawn; expired crops are logged.

## Decision: read the notice box

Use the game's command notices as the source of acceptance. No command-glyph
shape recognition is needed for v1. A valid-looking shape is not proof that
the game accepted it: the drone recording has recognizable MORE, LESS and
SPEED shapes accompanied by INVALID COMMAND.

| Notice in the English recordings | Category | Stored command |
|---|---|---|
| SIMPLE HACK | Presentation speed | simple |
| COMPLEX HACK | Presentation speed | complex |
| REQUEST KEY | Gear / key request | more |
| NO KEY | Gear / key request | less |
| ONLY KEY | Gear / key request | speed |
| INVALID COMMAND | Rejection | No accepted-command update |

The two categories are independent. The last **accepted** command in each
category wins. A gear command does not erase a presentation-speed command,
and vice versa. SPEED belongs to the gear category; it is not COMPLEX and
does not mean the result screen's Speed Bonus.

The player's rule is that gear commands do not apply to drone hacks. Store
hack mode separately as portal, drone, or unknown. For a confirmed drone
hack, effective gear mode is notApplicable, even if an attempted command
was visible. INVALID COMMAND alone cannot identify the attempted glyph or
prove that a hack used a drone.

Official sources confirm that
[SPEED restricts output to Portal Keys](https://ingress.com/news/2024-itoensoftbankyear10)
and that [drones cannot obtain Portal Keys](https://support.ingress.com/hc/en-us/articles/41140343208603-Dronenet).
The last-command-per-category rule comes from the player and the replacement
sequences below; these official pages do not specify replacement semantics.

## Recording evidence

Private originals remain local. No portal names, player names, map images or
addresses belong in committed fixtures. Times below are seconds into each
archive's screen-recording.mp4. A 10 Hz OCR inspection of a notice-only crop
was combined with visual frame inspection and the existing JSONL logs.
Approximate notice intervals are not production-reader benchmark results.

### Portal recording: 2026-09-28T20-50-18Z

About 345.8 seconds, seven tracked Glyph hacks. All five accepted notice
types are present. The final notice of each category before presentation is:

| Hack | Presentation starts, log elapsed | Speed command | Gear command | Recorded gear: keys / other items |
|---|---|---|---|---|
| 1 | 10.75 s | complex | less | 0 / 9 |
| 2 | 39.61 s | simple | more | 2 / 10 |
| 3 | 86.88 s | simple | more | 2 / 15 |
| 4 | 137.19 s | complex | speed | 3 / 0 |
| 5 | 248.83 s | complex | less | 0 / 8 |
| 6 | 287.49 s | complex | speed | 2 / 0 |
| 7 | 316.60 s | complex | more | 3 / 12 |

Gear quantities are the existing gear-drops.jsonl groups, a consistency check,
not evidence to feed back into command classification or an independent audit
of every item. The command columns are annotations from the notices.

Useful replacement tests include COMPLEX -> SIMPLE before hack 3, several
MORE/LESS/SPEED replacements before hack 4, and NO KEY -> REQUEST KEY before
hack 7. Command activity is sometimes much longer than a few seconds: do not
expire a command window just because the usual opening countdown passed.

Critical original-frame check before hack 7:

- 314.253333, 314.303333 and 314.353333: NO KEY.
- 314.403333: REQUEST KEY.
- 314.453333 onward in the inspected interval: notice absent.

The final replacement exists in **one captured frame at 20 Hz**. Requiring
two frames for every command would retain the wrong earlier setting. The
notice can change directly to another notice, with no blank in between.

### Drone recording: 2026-09-28T23-03-49Z

About 63.4 seconds, one tracked five-Glyph hack. DRONE FOOTAGE is visible
before command entry. During command entry there are repeated INVALID COMMAND
notices, accepted COMPLEX HACK notices, then SIMPLE HACK around 26.2 seconds,
then COMPLEX HACK around 27.7 seconds, then INVALID COMMAND around 28.9 seconds.
Presentation starts at logged elapsed 31.12 seconds.

Expected final annotation: presentation speed complex; hack mode drone;
effective gear command notApplicable. Preserve rejection events for diagnostics
without claiming which command was rejected. The existing gear log records
14 non-key items and no keys.

## Existing code and integration constraints

- The glyph CSV already contains all five shapes. Adding templates would not
  solve the acceptance problem.
- HeaderTextRecognizer reads only the header band, 6.0–10.4% of frame height
  in GameUILayout. The notice lies below it. Inspection used a 16–29% crop;
  production bounds must be measured and verified against fixtures.
- HeaderPhraseMatcher understands COMMAND CHANNEL OPEN, not these notices.
  The floating window covers the header in these samples. The drone log has
  no command phase; the portal log has only five samples marked command.
  Do not require PresentationTracker.state == command to read a notice.
- PresentationTracker intentionally excludes command strokes from sequence
  slots. Keep that separation; the new observer must not mutate its slots,
  hack counters, or PlayerInputValidator.
- GameTextSchedule and GameHeaderReader share one OCR lane. Adding an
  independently scheduled notice reader would violate that budget.
- hackID is allocated at presentation, after command entry. Pending command
  evidence needs its own window identity before it can be attached to a hack.
- HackResultSummary currently has no command or hack-mode fields.
  HackResults.receive ignores updates after a key closes. Resolve or mark
  command evidence unknown before publishing the closed summary; do not
  rely on rewriting history after closure.
- HackResultStore stores encoded summaries inside SwiftData records and
  supports iCloud. Additive optional fields can preserve old JSON without a
  new SwiftData entity. Prove compatibility, including older payloads and sync,
  rather than incrementing the store schema unnecessarily.
- HackStatistics currently mixes command modes, and itemsPerHack includes
  partial readings. Command-aware comparisons need explicit coverage and
  denominators, not just a label on the existing average.

## Recognition and lifecycle rules

1. Detect the small notice box on every available analyzed frame, with a
   compatible Glyph-array screen. Require spatial context, a known complete
   phrase and sufficient text confidence. Do not match arbitrary map text,
   PiP text, a result name such as SIMPLE, or a glyph shape during player input.
   Notice evidence may establish a command window even when its header is
   covered. Separately observe opening/exit context for windows with no notice.
2. Capture a small crop when the box appears or its contents change. Changes
   without disappearance are separate candidates. Keep a bounded queue of
   source-timestamped crops for the shared OCR lane, so the one-frame final
   notice is not lost just because OCR is busy. Deduplicate unchanged frames,
   cap memory and delay, and report queue overflow as missing evidence.
   The crop-change threshold and bounds are M1 measurements, not fixed guesses.
3. Prefer repeated agreeing reads where available, but allow one clear frame
   with an exact allowlisted phrase, valid box geometry and valid screen context.
   Record single-frame provenance. Do not require a 100 ms dwell. A low-confidence
   or conflicting reading stays unresolved; never fuzzy-match NO KEY into ONLY
   KEY. M1 must validate single-frame precision against negative fixtures.
4. Use source time, session ID and command-window ID for ordering and ownership.
   Repeated reads of the same notice are not extra commands. INVALID COMMAND
   records a rejection and does not overwrite either accepted setting. Do not
   infer the rejected shape, a reset, or drone mode from that generic message.
5. A later unreadable notice could replace either category: keep earlier values
   as lastObserved, but mark effective values uncertain where replacement cannot
   be ruled out. A later readable accepted notice can resolve its own category.
   Missing/covered evidence is not evidence of no command.
6. Bind a pending window once to the immediately following verified hack start.
   Freeze its source-time boundary at presentation. Drain already captured,
   bounded pre-boundary OCR work without blocking sequence recognition; reject
   post-boundary or wrong-session work. Finalize unknown if draining cannot finish
   before the summary must close. Drop pending ownership on cancellation, app
   departure, capture discontinuity, orientation change or a new unrelated window.
   Never attach an abandoned/cooldown attempt's commands to a later hack.
7. Read explicit drone context (for example the measured DRONE FOOTAGE footer)
   through the same OCR budget and associate it with the uninterrupted pre-hack
   screen sequence. Detect normal portal context positively too. An absent drone
   label, no keys, or INVALID COMMAND does not establish portal mode. If the
   mode cannot be established, retain unknown; no global sticky drone flag.
8. Persist category values plus coverage/provenance and hack mode. Distinguish
   noCommandObserved, unresolved and notApplicable from a confirmed command.
   For v1, noCommandObserved is not a confidently observed default policy.
   Old history stays unknown and is never backfilled from item counts or timing.
9. English notice recognition is evidenced here. Support additional game
   languages only with verified phrases and fixtures; CJK portal-title OCR does
   not imply command-notice localization support. Localize app labels under
   TRANSLATION.md regardless of which game notices are supported.

## Statistics and display

- Each hack's history shows presentation speed, gear request and hack mode,
  including unknown/uncertain when applicable. Example: “Complex · Keys only ·
  Portal”; drone gear policy is shown as not applicable.
- Store this small structured metadata under the existing Keep results setting,
  independently of diagnostic recording. Full notice events and cropped evidence
  remain controlled by logging settings, with rate/count caps and no map/header
  text in saved notice crops.
- Filter/group gear statistics by portal/drone/unknown and final effective gear
  request. Keep the existing portal level, hack length, game bonus, ITO effects
  and multiplied-drop information available; command grouping alone does not
  make different hacks statistically equivalent.
- Separate key quantities from non-key gear. Include keys-only hacks in overall
  observed totals but place them in their own yield comparison group. Drone
  hacks never enter a MORE/LESS/SPEED comparison, and uncertain command records
  never silently enter the default group.
- For command yield comparisons, use only attached groups with sufficient panel
  coverage; show included hacks and excluded/partial counts. Partial readings
  remain in labelled observed totals. Unread gear is not zero gear. Do not infer
  that no bonus panel was expected merely from SPEED or from no notice.
- History and statistics are the v1 display scope. Optional live PiP/Island
  command labels can follow; if added, include fields in snapshot revision,
  GlyphPiPRenderLoop's render key and GlyphActivityContentState.semanticKey.

## Build order and release gates

### M1: replay and evidence rules

1. Add sanitized notice crops, screen-context negatives and timestamped
   annotations from both recordings under Fixtures/Commands. Include the
   original one-frame REQUEST KEY. No full private frame is committed.
2. Add framework-free CommandFrameEvidence, CommandNoticeParser,
   HackCommandSummary and CommandObservationSession in GlyphRecognition.
   Tests cover category replacement, rejection and source-time ownership.
3. Add CommandNoticeDetector and CommandNoticeReader in GlyphRecognitionImages,
   plus hack-mode evidence reading. Reuse ResultTextLine where useful. Keep
   geometry/text reading separate from the reducer, as result recognition does.
4. Add the bounded crop queue and shared-lane scheduling, reused by replay and
   live code. Measure latency before choosing exact queue limits. Preserve
   header cadence and result/gear priorities; dropped candidates produce
   explicit coverage loss. The new path must work without drawing recognition.
5. Add glyph-replay --commands off|live|exhaustive and
   Tools/check-command-replay.py, following the result replay tools. Test the
   real scheduling path with delayed completions, not just exhaustive OCR.

M1 gates: reproduce the final command annotations for seven portal hacks and
the drone hack, especially the one-frame final MORE; reject map/result/input
look-alikes; do not turn drone SPEED drawings into accepted commands. Measure
missed-notice and uncertain-final coverage separately from incorrect finals.
Run phase, result and gear replay gates to prove the shared lane still works.

### M2: live capture and saved history

Wire the observer in LiveGlyphOutput, bind on tracker hack-start events and
carry the frozen metadata into ResultObservationSession / HackResultSummary.
Add bounded diagnostic events and optional notice crops. Update HackResultCard
or HackSummaryCard and localization. Verify old JSON decoding, new round trips,
closed-key behavior, retention, logging off, capture restarts and iCloud copies.
Keep the existing result/gear association queue unchanged unless a separately
demonstrated issue requires a change.

### M3: command-aware statistics

Update HackStatistics, GearTotalsView and the results filters with explicit
mode groups, key/non-key quantities and coverage denominators. Test mixed old
and new records, single-frame acknowledgements, partial/unattached groups,
unknown mode and drone exclusions. Run full package and app suites and the iOS
device build before shipping the complete feature.

## Peer review (2026-09-28)

The decision to read the notice box, not the command shapes, stands. The code
facts above were checked: the 6.0–10.4% header band, the COMMAND CHANNEL OPEN
phrase, the hack ID assigned at presentation, closed keys ignored by
HackResults, and the absence of command fields in HackResultSummary. The frames
before hack 7 were checked by eye: NO KEY at 314.203–314.353, REQUEST KEY at
314.403, and no box from 314.453. The notice replaces the previous one with no
blank frame, and the box's width changes with its text.

Changes to the plan, most important first:

1. **The display delivers about 60 fps; analysis samples 20 Hz.** frames.csv
   shows a frame every ~17 ms, while recognition.jsonl and the movie advance
   every 50 ms. The final REQUEST KEY was probably on screen for 50–100 ms and
   sampled once. During a command window, run the cheap box detection on every
   delivered frame and queue OCR only for a changed box (width and ink make a
   good change signal). Then two agreeing reads can stay the default, with a
   single read as a recorded fallback. The 20 Hz replays cannot test this; M1
   needs one field recording at the full frame rate.
2. **Ship in two steps.** M1 and M2 (read, record, show each hack's commands)
   are useful on their own and prove the reader in the field. Narrow M3's first
   version to keys and other items per hack by gear command; wider groupings
   can follow real data.
3. **Store the game's meaning, not glyph names:** `requestKey`, `noKey`,
   `keysOnly`, and `simple`, `complex`. "speed" invites confusion with the
   Speed Bonus, and the statistics are about keys.
4. **Attach at hack start.** Commands are final before presentation, and the
   result tracker is created at input. Carry the frozen commands into its
   context then; the result closes 10–20 s later, so draining notice OCR before
   closure should rarely matter.
5. **Look for a pixel signal for drone mode before adding OCR.** A DRONE
   FOOTAGE read competes for the shared lane. The existing gear recordings are
   drone hacks and can be measured. If OCR is needed, read the footer once per
   hack at low priority.
6. **Keep multiplied drops out of command yield comparisons,** or show them
   apart: a first hack of the day would otherwise inflate whichever command it
   used.
7. **A floating window over the notice region is missing evidence,** as covered
   indicators already are, never "no command". Measure where the window can sit
   relative to the 16–29% band and add it to the evidence list.

Smaller points: add valid, invalid, valid at a portal to the rejection
evidence; record which game language a notice was read in, so unsupported
languages stay unknown rather than "no command"; SIMPLE/COMPLEX could later
inform presentation timing, as a separate follow-up that keeps the tracker
separation above.

## Additional evidence to collect

- No-command hacks with the entire opening visible; capture beginning midway
  through commands; cancellation followed by another hack; rapid drone/portal
  switching in one session.
- The notice box covered by PiP, delayed/busy OCR and more one-frame notices.
- Localized command notices in Chinese, Japanese and Korean, and smaller-screen
  layouts. Unsupported text must remain unknown until verified.
- A deliberately invalid command after a valid one at a portal, to confirm
  rejection preserves the previous setting independently of the drone sample.
- Redo during command entry, if the game allows it: do not assume it has the
  same semantics as Redo during the scored Glyph input.

These recordings are enough to start M1. They do not establish universal
notice timing or layout support. No implementation, staging or commit is part
of this planning change.
