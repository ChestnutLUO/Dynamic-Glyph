# Covered indicators and adjustable PiP

## Recognition evidence

The live pipeline now treats header text, slot indicators, the countdown bar,
and the drawing array as separate regions. An overlay over the indicators no
longer suppresses OCR of a visible header. The countdown is read even when the
indicator reader rejects the strip; within an observed hack, a visible countdown
and valid array calibration stop presentation collection and enter player input.
A countdown alone cannot start a hack on an unrelated screen.

The indicator reader also checks that the row occupies the expected centred
positions. Covering one side of a four-slot row therefore cannot make its two
remaining markers a trusted two-slot row. Countdown evidence requires the full
track at its expected endpoints, including its violet remainder as gold drains;
a shorter gold PiP status edge is insufficient. These checks use the recorded
portrait layout. They do not detect every overlay: symmetrically hidden outer
markers can still resemble a shorter centred row, and other layouts need
labelled captures before their geometry can be supported.

When presentation text is readable but the indicators are not, the tracker can
retain a provisional sequence of visible shapes:

- Shapes still need independent supporting frames. Nested shapes within one
  drawing retain the largest stable shape; unrelated shapes remain uncertain.
- Two clear-array samples at least 45 ms apart separate inferred entries. This
  accommodates the annotated recording's 100 ms blank intervals at 20 Hz.
  A single blank frame or a held exact match cannot close an entry.
- Repeated glyphs separated by a clear interval remain separate observations.
- Entries have `inferred` status and dashed diagrams. Their positions are
  unverified, including whether capture joined after the first glyph.
- Inferred entries never enter `confirmedPrefix`, sequence prediction, or
  next-glyph guidance. Sequence length is not inferred from their count.
- When indicators return during presentation, guessed positions are discarded
  and tracking resumes at the actual highlight. Earlier unverified positions
  become gaps; the tracker does not promote them into confirmed slots.
- Capture gaps, invalid calibration, an obscured array, or missing phase evidence
  prevent temporal segmentation. Collection is bounded to five entries.

If both header and indicators are hidden, the tracker still abstains after its
short phase grace period. This change does not recognize arbitrary notification
content or invent missing slots. Blank intervals do not prove glyph completion;
that is why this path stays provisional even when all retained shapes look right.
The existing English portrait layout and cached calibration requirements apply.

Logs include separate overlap flags, independent timer visibility, and
`slotInferred` events. The replay tool reports inferred entries separately from
commits.

## Notification banners

An iOS notification that arrives during a hack hangs over the header and the
top of the indicators while the game carries on underneath. The strip reader
now finds such a banner: a run of rows at the top of the strip in which at
least 75% of the columns are lit. The game's own indicators light at most about
a quarter of a row. The row is then read only below the banner's edge. Every
marker must reach up to that edge and still show at least 0.4 of its width in
height. The count, pitch, centring and single-highlight checks are unchanged.
The frosted copy of the indicators inside the banner is never read. A banner
reaching the bottom of the strip leaves nothing readable. Readings taken this
way are logged as `slotStripPartlyCovered`.

The relaxed height rule applies only to bright, full-width banners and to the
lower edge of our own floating window (see "Our own window's lower edge across
the strip"). Any other thin window whose lower border crosses the strip can
also be read below that border, but still has to pass the ordinary
full-height rule. A dark window covering more of the indicators, or a cover
over part of the width, remains subject to the full-height and complete-row
checks.

Replay of a five-hack field session at 20 frames/second: the version that
recorded it lost the two hacks with a message banner up (`all, chaos, not,
body` with the banner over the whole presentation, and `attack, weak, shapers,
lie` with it arriving before the first Glyph). Now all five hacks in the run
are confirmed from the indicators, 20 of 20 slots, with no extra hack or
invalidation. The annotated phase-replay recording and two other field runs
produce the same tracker events as before.

## A window over the strip before any hack is seen

With the header and the indicators both under the floating window, no hack can
be seen starting, and the display used to keep saying it was waiting for one.
In one field session the window, at its 384×96 canvas, left 7 rows
of the indicators visible; all four Glyphs were matched and none reached a
slot.

The strip reader now reports `coveredByOverlay` when a lit row crosses the
strip below anything hanging from its top: the game's indicators never light a
whole row, a window's border does. A window whose border only touches the top
of the strip, as in an earlier field run, is skipped and the row is read. Outside
a hack, the tracker raises the obstructed status when that lasts past the
obstruction grace while the array itself is in view, clear or showing a Glyph.
A calibration cached from the Glyph screen does not raise it on the home screen
or the app switcher. The status is "Slot row covered · move the window"; no
hack, slot or sequence is inferred from it.

Replay: that run is flagged for the whole time the Glyph screen was up
(17.5–25.8 s). The replays of four other field recordings keep their
sequences, and raise it nowhere outside a hack.

## Thin PiP over the indicator tips

Two captures from one field session use a 380 × 38 point PiP window.
Its lower border cuts across the very top of the four indicators while most
of each indicator remains visible. The previous reader rejected the entire
strip on seeing that border: the two recording logs contain no tracking events,
despite successfully recognizing individual Glyph shapes on the array.

The reader now excludes rows through the last broad overlay border, plus its
shadow tolerance, then checks the remaining pixels. Every marker still needs
height at least 0.8 times its width, and the existing count, pitch, centering,
width and single-highlight rules all apply. The window's own content is
excluded. This is a stricter height requirement than the notification-banner
fallback; it does not treat a few exposed pixels as a whole row. If the row
cannot be recovered, the rejection stays `coveredByOverlay`.

With no collected sequence and obstructed indicators, the PiP caption now uses
the shared localized status: “Slot row covered · move the window.” Previously
its border showed a warning while its caption still said to start a hack.

Replay uses each movie's original timestamps and encoded 602 × 1310 frames:

| Capture | Frames | Original confirmed slots | Confirmed slots after fix |
|---|---:|---:|---|
| First thin-window capture | 567 | 0 | soul, rebel, human, die |
| Second thin-window capture | 712 | 0 | ignore, human, chaos, lie |
| Third capture (Island only) | 823 | 4 | stability, together, defend, truth |
| Fourth capture | 388 | 0 | None; no presentation established |

Both recovered PiP sequences use indicator transitions while the header is
covered, with four confirmed slots each and no inferred entries. Tests compose
the real PiP renderer over game fixtures to cover both warning and normal
borders, reject deeper covers, and reject PiP content without game indicators.
The original deeply covered seven-row fixture remains rejected.

This fixes recognition under the recorded thin-window placement. It does not
move the system window or recover pixels hidden behind a larger overlay.

Verification: all 216 package tests and 53 app tests passed, including the
package suite on both macOS and the iOS 27 simulator. The iPhone app and widget
built with signing disabled. The original annotated recording still recovers
`see, truth, see, future, begin`; the correct-input baseline retains two matches,
two unavailable checks and zero `differs`. On-device behavior with the rebuilt
app still needs a retest at the same window placement.

## A window edge along the top of the strip

In a field report (644 × 1398), called the window-edge report below, the
window sat directly above the indicators. Its lower edge lit the first five
rows of the strip and lay across the tips of the hexagons. That is one row
short of a banner, so it was neither read beneath as one nor caught by the
thin-window rule, which looked only below that run. The header was never
readable, and the hack (`discover, shapers, enlightenment`) was recognised
from the indicators alone at 7.86 s. On the next frame the window's edge
turned teal for "collecting". The reader counted the teal as indicator violet,
merged the edge into one full-width marker, and rejected the frame
(`inconsistentMarkerWidths`). A presentation entered through the indicators
has no grace period, so it ended on that one frame and nothing was collected.
During input, every frame with the lavender "drawing" edge was rejected the
same way.

Every status colour of the window's edge passes as indicator violet or gold,
including idle grey and warning red, so any status could do this. The reader
now treats a lit run at the very top of the strip, however short, as a window
edge. It reads below that edge with the thin-window rule and its ordinary
full-height check. Such an edge reaches only the indicator tips. When nothing
readable lies below it, the reader reports the real reason, not
`coveredByOverlay`, so a window placed out of the way does not raise "Slot row
covered · move the window" on every screen without a strip. A reading below a
window's edge is marked partly covered only when the indicators run up to the
cut.

Replay with the recording's own timestamps now confirms all three slots from
indicator transitions, and both input checks match. From 9.76 s to 13.16 s,
every input frame reads three slots with the highlight advancing. The only
readings that change are the frames the edge had broken. The ablation corpus
(12 hacks, 17 variants) produces results identical to the previous build. The
recording frames that pin this down are in `Fixtures/WindowEdge/`. The tests
also draw the real window renderer in every status tone across the strip's
first rows. All of those tests fail against the previous reader.

## An AssistiveTouch button beside the array

In another field report (602 × 1310), only the
first of three hacks was collected. An AssistiveTouch button was
parked at the left edge of the screen, just above the array's left column. Its
rim reached about 5 px into the array's bounding box, in the corner outside
the hexagon of outer nodes. The empty-array check counted every bright pixel in
that box as stray ink, so the empty array never read as clean. The array was
therefore never calibrated. Starting a hack from the indicators also needs the
empty strip over a clear array, so it could not happen either. The first hack
worked only because the button then sat on the bottom-left node, where the
node mask hid it. Its calibration expired eight seconds after that hack ended,
and hacks 2 and 3 were never entered, although all 11 nodes were visible.

Stray ink now counts only within the hexagon of outer nodes, plus a stroke's
glow (the radius already used for explained ink). No lattice edge lies in the
corners outside it. Replay with the recording's own timestamps now collects
all three hacks from indicator transitions: `grow, unbounded, create, new,
future`, `save, before, refresh` and `mind, open, breathe`, all rows of the
sequence table. The one input check that differs is hack 2's second slot. The
player drew `grow` for `before`, which the game's result screen also marks.

The ablation corpus changes in one hack only, where the floating
window crosses a corner of the array during slot 4. Before, that slot had no
shape evidence and was `missing`. It now has evidence: `uncertain` in the
baseline, and correctly confirmed as `destroy` with the stability rule off
(35 → 36 correct). No answer became wrong in any variant. The correct-input
baseline recording still gives four matches and no `differs`, and the
window-edge report still recovers `discover, shapers, enlightenment`.

This does not help when the button sits alongside the array's left or right
column: there its rim is inside the hexagon, next to a real outer edge. The
fixtures are in `Fixtures/AssistiveTouch/`, with a synthetic check that
stray ink inside the hexagon still counts.

## An object at the screen's side edge

In a field report (603 × 1311, game in Traditional Chinese), a tucked floating window's grey tab sat at the
right edge. It lit 0.939 of the width to the edge, and 0.069 to 0.182 of the
height. It covered no game text and no indicator. The strip reader took its
grey for indicator violet, so the tab became a 37 px marker, too narrow for an
indicator. Every frame showing it was rejected as `inconsistentMarkerWidths`:
113 command-screen frames in a row. Drawn onto eight hack frames, the tab made
all eight unreadable on both engines. It also lit the top rows of the command
band, so the notice's bounding box ran to the edge and to the band's top. The
box then failed its centring and `top > 1` checks, and the notice was never
read. Neither failure was `coveredByOverlay`, so the app gave no warning.

Both readers now set such an object aside. Their own geometry decides where,
not the tab's:

- **Slot strip.** An outer indicator is centred at most 0.355 of the width
  from the middle (2 × 0.16 + 0.035), and an indicator is 0.085 to 0.190 wide.
  So none comes within 0.05 of an edge, and none starts within 0.1875 of the
  right edge or ends within 0.1875 of the left. Less a 0.01 allowance, that
  gives a margin of 0.04 and a zone of 0.1775 (`slotEdgeColumns`). A run of
  indicator-coloured columns that lies wholly within the zone and reaches the
  margin holds no whole indicator, and holds something that is no part of
  one. It is not counted as a marker. A run that also takes in an indicator
  reaches as far in as the indicator, so it is kept and rejected as before.
- **Notice box.** A box is centred within w/16 and is w/5 to 4w/5 wide, so it
  spans the centre column and stays 0.06875 of the width from either edge. A
  run of lit columns that reaches within w/20 of an edge and stays on that
  side of the centre column is left out of the bounding box.

A plain margin of ignored pixels could not do this. The tab begins at 0.939
of the width, inside the 0.95 that the reader's tolerances let a five-slot
row's outer indicator reach, and only 0.008 beyond the reach of a notice box.
The measured outer indicators end at 0.885.

The whole-row test still counts every column. On a strip screen the
indicators light at most 0.27 of a row in the fixtures, so a tab 0.06 wide
cannot make a row whole (0.75). On a busy result screen it can
(`Results/three-final.png`, 0.70 lit): `inconsistentMarkerWidths` becomes
`coveredByOverlay`. The warning needs the array in view, so nothing shown
changes, and the test was left as it was. The countdown track is found as
before beside the tab, which is separated from the track by more than its gap
allowance. An edge object reaching within 3 px of the track's end would hide
it; none has been seen.

The tab is in `Fixtures/EdgeTab/`, and the notice band from the report is
`Fixtures/Commands/complex-edge-tab.png`. `EdgeObjectTests` draws the tab over
every fixture, at the right edge and mirrored at the left. Read strips and
`coveredByOverlay` verdicts must stay as they were, no frame may gain a strip,
and every notice box must keep its rectangle and signature. Hand-authored
scenes check that an edge object touching or reaching over an indicator, or
starting where one could, is still rejected.

## Our own window over one side of the strip

In a field report (603 × 1311, English game), called the window-cover report
below, our floating window opened out of its edge tab 0.6 s into player
input. It came to rest over the right half of the slot strip and the countdown,
from column 306 to 16 px short of the right edge. From 10.1 s the full row and
the countdown's right end were hidden, while the countdown ran on beside the
window until 17.25 s. The version that recorded the run lost the countdown at
10.09 s. It kept input only while the header still read "GO!", and ended it at
12.94 s (`input -> interrupted via none`), more than 4 s before the player had
finished.

The strip reader now looks for our window when the full reading fails, some
indicator-coloured marker remains, and no banner or window edge crosses the
strip. A side of the window is a run of columns lit in at least 0.9 of the
strip's rows. The game's indicators, glow included, light at most 0.74 of them.
The run must be 0.04 of the strip's height to 0.06 of the width thick, one
colour down its middle column (each channel within 24 of the median), and have
an interior beyond it at least 40 grey levels darker. The interior is sampled
past one column: the pixel the ring's inner boundary crosses blends ring and
interior, and whether it is lit depends on the ring's colour and where the
boundary falls. The window's far side must light a column within 0.05 of the
frame edge, and only one edge may have one. The reader then reports:

- the covered columns, from the window's inner side to the frame edge;
- the markers wholly outside them, held to the ordinary width, height and
  single-highlight rules, as fractions of the width;
- whether the countdown shows beside the window. On one row of the countdown,
  a run of rail must start within 0.035 of the width of the rail's visible end
  and continue, with gaps of at most 0.005 of the width, up to the window. The
  run must hold progress as long as the full check requires. The empty rail
  drawn before input has no progress, and text has gaps.

It never reads the slot count from this. The tracker places the visible
markers only in a row of the count the full strip already showed. Each marker
must sit on that row's grid, in order, and every place without one must lie
under the window. Otherwise nothing is placed.

The countdown beside the window keeps input that is already established, as
the full countdown does, with the source `partialInputTimer`. It needs a valid
fit and a presentation seen for this hack. It never starts input, resumes it
after an interruption, or overrides a header naming another phase. The player's
slot is known only while its highlight shows beside the window. A highlight
under the window leaves the slot unknown rather than holding the last one seen.
The obstruction flag stays set, and the input check, which needs the full row,
reaches no verdict under the window. Result reading is unchanged. With power
saving on, the countdown beside the window keeps the full pace, as the full
countdown does. The recognition log gains `windowCover`, `windowCoveredFrom`,
`windowCoveredTo`, `partialInputTimerBar`, `partialSlotCenters` and
`partialSlotHighlight`. The replay reports frames with the window, with a row
beside it and with the countdown beside it as `windowCover`, only when there
are any.

Replay of the report at 20 frames/second, on the shipped arm and on four
others: input now runs from 9.10 s to 18.05 s, 0.8 s after the last countdown
frame. During it, slot 1 is shown from 10.25 s, slot 2 from 11.75 s, and from
13.0 s, with neither visible indicator lit, no slot. The hack's four Glyphs,
`technology, intelligence, grow, unbounded`, the result outcomes (accepted,
accepted, unknown, unknown) and the single hack are as before. The window
fixtures are in `Fixtures/WindowCover/`. `WindowCoverTests` also mirrors them
to put the window on the left. Every other fixture, and every fixture with the
edge tab drawn on it, finds no window.

No other recording finds the window, and none changes. That covers the eleven
other report recordings up to 160 s long on the shipped arm, including the
lower-edge report described in the next section. It also covers the edge-tab
sets on both engines, the phase replays of the annotated recording and the
window-edge report, the portal and drone command replays, the four-hack result
replay and the correct-input baseline. Their reports are identical,
timings aside. On the report's 590 frames the C++ strip read went from 43 µs to
67 µs on average on a Mac. Frames whose full reading fails pay for the search,
and here 524 of them do.

Those replays scaled the frames to the 603 × 1311 of `recording.json`. The
report's video is 602 × 1310, and a phone playing it lost input at 13.7 s.
Replayed at that size, input ended at 13.75 s, when the window's ring turned
from red to grey. In the native frames the grey ring's blend pixel is
(38, 48, 54), not lit, so it was sampled as interior: 44 against a ring of 79,
short of the 40 levels. Scaled, the same pixel is (55, 64, 71) and lit. Past
that pixel the interior is 28. With the interior sampled past one blend column,
input at native size runs from 9.10 s to 18.05 s on all five arms, as it did
scaled, with 299 window frames instead of 103. The scaled replay is unchanged.
`native-0211.png` and `native-0281.png` are the native frames, and the tests
read every window fixture at 603 × 1311, 602 × 1310 and 562 × 1218 on both
sides, in Swift and in C++. All 15 report recordings were replayed at their
native sizes (602, 562 and 644 wide) on the shipped arm. Only this report
finds the window, and every other report is identical. The lower-edge report at
both sizes, the edge-tab sets and the other replays above are identical too. On
the native frames the C++ strip read went from 57 µs to 67 µs, the same as
the scaled frames' 67 µs, because the search now finds the window and reads
beside it.

## Our own window's lower edge across the strip

In a field report (603 × 1311, English game, iOS 27), called the lower-edge
report below, our floating window sat at the top of the screen over the
header. It is barrel shaped there: a dark green interior, a ring of the
warning colour along its top and bottom, pointed ends. Its lower ring, rows
160 to 164 with an antialiased last row, lay across the top 15 rows of the
five hexagons (rows 150 to 225, 79 px wide), which showed about 60 rows below
it. The thin-window rule skipped the ring and the edge tolerance and read from
row 168: 58 rows, short of the 0.8 of the width it requires. Every frame from
the presentation to the end of input was refused as `coveredByOverlay`, the
window said "Slot row covered · move the window" throughout, and the version
that recorded the run tracked no hack.

When the thin-window rule fails, the reader now asks whether the covered row
is our window's lower edge:

- a band of rows, the last within the edge tolerance of the covered row, each
  one colour (each channel within 24 of the median) across 0.9 of the middle
  half of the covered row's lit span, and as bright as a ring (grey 60);
- 2 rows to 0.015 of the frame height thick;
- the rows one band thickness above it at least 40 grey levels darker, the
  window's interior.

The edge rises towards the window's ends, and on a smaller window its lowest
rows can light less than a whole row. So each column is followed down from the
band through pixels of the ring's colour, at most the band's thickness
further, and read only below that, the covered row and the edge tolerance.
Below that edge every indicator must reach up to the edge and show at least
0.4 of its width in height, as below a banner. The count, pitch, centring,
width and single-highlight checks are unchanged, and the reading is marked
partly covered. Because the search runs only after the thin-window rule has
failed, every row read before reads the same.

In the report's frames the ring took the warning, collecting, done and
idle colours. Its band was 4 or 5 rows thick, 0.92 to 1.00 of the sampled
columns one colour (the antialiased last row 0.87 to 0.90 in some frames, so
it may count or not), and 51 to 163 grey levels brighter than the interior.
The rounded window of a long benchmark recording also passes, but its ring
ends at the hexagon tops and those frames already read with the full-height
rule.

Replay of the report at 20 frames/second, scaled to the capture's size as the
app reads it, on the shipped arm and on four others: the hack is now tracked
from the indicators at 8.25 s, and `defend, human, civilization, shapers, lie`
are all confirmed from indicator transitions. Input runs from the countdown at
10.8 s to 19.3 s, with the player's slot followed from slot 1 at 11.0 s to slot
5 at 14.75 s. The first two input checks match and the next two reach no
verdict. The result reads four accepted and one rejected Glyph, as the game
showed, and the gear drop after it is now ordered to the hack. "Slot row
covered · move the window" shows from 5.5 s to 7.75 s, while the command screen
and the row's first frames are under the window, and from 18.85 s to 19.3 s;
before, it showed from 5.5 s to 24.05 s. Of the report's 614 frames, 216 read
a row, all of them through the new search. No frame read before.

Nothing else changes. The window-cover report on all five arms, the other eleven
report recordings up to 160 s on the shipped arm, the three long ones (346 to
543 s), the edge-tab sets on both engines, the two phase replays, the portal
and drone command replays, the four-hack result replay and the correct-input
baseline give identical reports, timings aside, but for one: in a field
recording with a one-Glyph hack, two frames of that
hack's input, with our window over the top of the single hexagon, now read the
row as the 17 frames after them already did. Its tracker events are unchanged.
In the first minute of the benchmark recording the edge is found on 774
of 1,200 frames, where nothing below it is a row, and no reading changes.

The search runs only on frames whose covered row the thin-window rule could not
read past, and only when what showed below that rule's cut could still hold a
row (`couldReadBelowWindowEdge`). The traced edge is never above the cut, so
the traced read counts a subset of the same pixels. Each marker it could find
lies within a run of columns already lit with indicator colour below the cut,
and is no taller than that run's indicator rows. A row needs, for some count
from one to five, a marker at every place of the centred grid, at least the
minimum width wide and 0.4 of that tall. When no run can hold one at some
place for every count, the search cannot succeed and is skipped. A read below
the cut that stopped at another whole lit row skips it too: the traced read
shares those rows. On map, command and other screens under a window that ends
inside the strip, the search is nearly always skipped.

The first version of the search cost a phone about 1% more CPU on the
benchmark recording: there the window ends at the hexagon
tops, so during hacks the thin-window rule reads, and the search ran on the
other screens. On the first two minutes of that recording at its native size,
1,733 of 2,400 frames reach the search and 1,624 now skip it. On a Mac the
C++ strip read on those 1,733 frames took 79.5 µs before the search, 156.6 µs
with it and 86.0 µs with the gate, and 81.3, 137.9 and 86.6 µs on all frames.
The per-pixel loop also has a copy without the edge test, for the reads
without an edge. On the lower-edge report scaled to 603 × 1311, 236 of the 511
frames that reach the search still run it, the 216 that read among them, and
the strip read averages 96 µs against 124 µs ungated and 66 µs before the
search. Every reading on every frame of both reports at both sizes, of the
first two minutes of the benchmark recording and of the one-Glyph recording,
and every replay, is the same with the gate as without it.

The fixtures are in `Fixtures/WindowLowerEdge/`. `WindowLowerEdgeTests` reads
them on both engines; moves the window by a few pixels each way; recolours its
ring in every status colour; bows its edge lower in the middle; lowers it
until the indicators are too short (20 rows lower still reads, 32 rows lower
never does); replaces its edge or interior with something that is not our
window's; and removes or moves an indicator below it. The real window renderer
80 px tall over a four-slot fixture now reads the row below it in every status
tone, where it used to be refused.

## Island freshness

While the player draws, a change reaches the Island at most every 0.15 s and
unchanged next-glyph guidance is renewed every 1.5 s; in every other phase the
pace is 0.4 s and once a second. Only one update is with the system at a time,
and when it is acknowledged the newest held state follows, so two updates in
flight cannot finish out of order and leave an older one showing. The
three-second expiry is measured from evidence arrival, including when an
update waits behind the throttle. A timer alone cannot renew old guidance. A
newer observation always replaces queued content, including a return to the
already displayed state, so an obsolete intermediate glyph is not sent later.
Visible timing and system update limits still require a phone test: iOS may
coalesce or delay Live Activity updates it considers too frequent, and the
Diagnostics page reports how long each update took.

## PiP controls

Open **Settings → Floating window → Shape and sharpness**:

- **Width:** 256–640, in steps of 16.
- **Height:** 64–192, in steps of 8.
- **Sharpness:** 1×, 2×, or 3×; the resulting pixel dimensions are shown.
- **Apply:** saves settings and updates the render loop without reopening a
  dismissed window or restarting capture.
- **Reset:** restores the standard 640×64 row at 2× (1280×128 pixels, 10:1).
  Earlier versions used 384×96 at 1×.

First-run setup sets the shape and the sharpness on one page, with a ticked
slider for each. The shapes are 5:1, 6.7:1, 8:1 and 10:1 (the standard); the
sharpness is 1×, 2× (the standard, 1280×128 pixels) or 3×. A looping demo drawn
by the same renderer previews the choice. The page warns that any shape taller than the standard covers
more of the game: a window over the slot row stops recognition, so it should be
dragged down or tucked against the side while the sequence is shown.

All glyphs remain in one horizontal row. The inline preview follows the applied
aspect ratio. Canvas changes recreate the pixel pool and format description,
flush old queued frames, and invalidate cached pixels on the render queue.
Resolution scales the whole drawing.

These controls set source geometry and sharpness. iOS chooses the floating
window's actual dimensions and placement. The readout reports the system's
render size separately. A source ratio change may not remove system letterboxing
or lower the minimum window size. Pinching, moving, edge-tucking, and Island-only
mode remain the available device controls.

## Verification

Package coverage includes region isolation, timer reading with covered indicator
pixels, nested shapes, repeated glyphs, one-frame blanks, capture gaps, unknown
phases, restored indicator positions, and bounded inferred entries. Canvas tests
check clamping and that width/height extremes keep their proportions. They do
not establish comfortable glyph legibility at every setting.

### Recorded-pixel replay

Source: the annotated five-Glyph field recording, seconds 24.5–28.5,
20 frames/second, 603×1311. The expected sequence comes from its manual
annotation, which is not published.

The whole indicator strip was covered with a black rectangle before replay:

```sh
mkdir -p /tmp/dg-covered-strip-replay
ffmpeg -hide_banner -loglevel error -y -ss 24.5 \
  -i <recording>.MP4 -t 4 \
  -vf 'fps=20,scale=603:1311,drawbox=x=0:y=137:w=603:h=94:color=black:t=fill' \
  /tmp/dg-covered-strip-replay/frame-%04d.png

swift build --package-path Packages/GlyphRecognition --build-system native \
  -c release --product glyph-replay
Packages/GlyphRecognition/.build/release/glyph-replay \
  --glyphs Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/glyph_line.csv \
  --sequences Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/glyph.csv \
  --expect see,truth,see,future,begin --quiet \
  /tmp/dg-covered-strip-replay/frame-*.png
```

Observed result: 80/80 frames rejected the indicators as `noMarkers`. All five
shapes were retained in order, with supporting sample counts 5, 6, 6, 5, 6.
All five were `inferred`; confirmed commits were zero, `confirmedPrefix` was
empty, sequence length stayed unknown, and prediction remained `unobserved`.
The final phase was player input. Header OCR was run synchronously for this
replay; live asynchronous OCR latency is a separate device check.

## iPhone acceptance checks

1. Apply width/height extremes with the window closed, then open it. Confirm the
   preview and glyph orientation, whole sequence, and actual
   system window dimensions. Repeat with the window open.
2. Change resolution only. Proportions must remain the same. Confirm no stale
   frame, failed renderer, unexpected PiP reopening, or capture restart.
3. Relaunch the app and confirm applied settings persist. Reset and verify the
   default thin row returns.
4. Cover only the indicators during a presentation, leaving its text and array
   visible. Expect dashed inferred entries, including repeated glyphs; no
   confirmed prefix or next-glyph instruction should appear from those entries.
5. Move PiP away mid-presentation. Verify the actual highlight re-anchors the
   display and guessed earlier positions become gaps.
6. Cover the header as well, and separately cover the array. Expect abstention,
   not new confirmed observations. Repeat with an ordinary notification banner.
7. Keep the indicators covered into player input while leaving the countdown
   visible. The sequence must freeze; player drawings must not add entries.
8. Check Done and Back remain reachable. If system minimum sizing still blocks
   controls, use edge-tucking or Island-only mode and report the actual size.

A successful build and offline replay do not establish live PiP resizing,
notification robustness, or asynchronous OCR behavior on the phone.

The Release iPhone app and widget build with signing disabled. The documented
native Swift test runner is available when `make test` encounters the macOS
codesign metadata failure. No on-device acceptance result is claimed here.
