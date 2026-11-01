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

The relaxed height rule applies only to bright, full-width banners. A thin
window whose lower border crosses the strip can also be read below that
border, but still has to pass the ordinary full-height rule. A dark window
covering more of the indicators, or a cover over part of the width, remains
subject to the full-height and complete-row checks.

Replay of `spikeB-2026-09-23T00-14-36Z` at 20 frames/second: the build that
recorded it lost the two hacks with a message banner up (`all, chaos, not,
body` with the banner over the whole presentation, and `attack, weak, shapers,
lie` with it arriving before the first Glyph). Now all five hacks in the run
are confirmed from the indicators, 20 of 20 slots, with no extra hack or
invalidation. The 2026-09-17 phase replay, the 2026-09-22 run and the
2026-09-18 run produce the same tracker events as before.

## A window over the strip before any hack is seen

With the header and the indicators both under the floating window, no hack can
be seen starting, and the display used to keep saying it was waiting for one.
In `spikeB-2026-09-23T02-38-17Z` the window, at its 384×96 canvas, left 7 rows
of the indicators visible; all four Glyphs were matched and none reached a
slot.

The strip reader now reports `coveredByOverlay` when a lit row crosses the
strip below anything hanging from its top: the game's indicators never light a
whole row, a window's border does. A window whose border only touches the top
of the strip, as in the 2026-09-22 run, is skipped and the row is read. Outside
a hack, the tracker raises the obstructed status when that lasts past the
obstruction grace while the array itself is in view, clear or showing a Glyph.
A calibration cached from the Glyph screen does not raise it on the home screen
or the app switcher. The status is "Slot row covered · move the window"; no
hack, slot or sequence is inferred from it.

Replay: that run is flagged for the whole time the Glyph screen was up
(17.5–25.8 s). The 2026-09-17, 09-18, 09-22 and 09-23 replays keep their
sequences, and raise it nowhere outside a hack.

## Thin PiP over the indicator tips

The 2026-09-23 15:07 and 15:08 captures use a 380 × 38 point PiP window.
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
| `spikeB-2026-09-23T15-07-45Z` | 567 | 0 | soul, rebel, human, die |
| `spikeB-2026-09-23T15-08-19Z` | 712 | 0 | ignore, human, chaos, lie |
| `spikeB-2026-09-23T15-09-00Z` (Island only) | 823 | 4 | stability, together, defend, truth |
| `spikeB-2026-09-23T15-10-15Z` | 388 | 0 | None; no presentation established |

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

In the user-reported `spikeB-2026-09-25T03-18-37Z` run (644 × 1398), the
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
recording frames that pin this down are in `Fixtures/Assets/Screenshots/WindowEdge/`. The tests
also draw the real window renderer in every status tone across the strip's
first rows. All of those tests fail against the previous reader.

## An AssistiveTouch button beside the array

In the user-reported `spikeB-2026-09-26T03-10-35Z` run (602 × 1310), only the
first of three hacks was collected. The player's AssistiveTouch button was
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

The ablation corpus changes in one hack only, `s0918-3`, where the floating
window crosses a corner of the array during slot 4. Before, that slot had no
shape evidence and was `missing`. It now has evidence: `uncertain` in the
baseline, and correctly confirmed as `destroy` with the stability rule off
(35 → 36 correct). No answer became wrong in any variant. The correct-input
baseline (`IMG_2003.MP4`) still gives four matches and no `differs`, and the
2026-09-25 report still recovers `discover, shapers, enlightenment`.

This does not help when the button sits alongside the array's left or right
column: there its rim is inside the hexagon, next to a real outer edge. The
fixtures are in `Fixtures/Assets/Screenshots/AssistiveTouch/`, with a synthetic check that
stray ink inside the hexagon still counts.

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
  Before 2026-09-23 the standard was 384×96 at 1×.

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

### Experimental playback-control hiding

**Hide playback controls** defaults on for the locally installed field app and
persists independently of the canvas settings. It requests the undocumented
`controlsStyle = 1` setting. Turning it off restores the controller's original
style. Updates apply to an existing controller and to newly created sessions;
they do not open a closed window or restart capture.

Both runtime accessors are checked before KVC is used. If unavailable, the app
keeps system controls and reports that hiding is unsupported. This check does
not guarantee the undocumented property's behavior on future iOS releases.
The workaround must be removed from an App Store target.

On the phone, verify play/pause and seek controls disappear while close and
return-to-app controls remain usable. Toggle off to restore transport controls,
then on again; reopen PiP if iOS does not refresh the existing window. Restart
the capture session and relaunch the app to check preference persistence.
Build success alone does not verify the system window's visible controls.

Package coverage includes region isolation, timer reading with covered indicator
pixels, nested shapes, repeated glyphs, one-frame blanks, capture gaps, unknown
phases, restored indicator positions, and bounded inferred entries. Canvas tests
check clamping and that width/height extremes keep their proportions. They do
not establish comfortable glyph legibility at every setting.

### Recorded-pixel replay

Source: `ScreenRecording_09-17-2026 23-56-50_1.MP4`, seconds 24.5–28.5,
20 frames/second, 603×1311. The expected sequence comes from the existing manual
annotation in `Tools/RecordingResults/2026-09-17/README.md`.

The whole indicator strip was covered with a black rectangle before replay:

```sh
mkdir -p /tmp/dg-covered-strip-replay
ffmpeg -hide_banner -loglevel error -y -ss 24.5 \
  -i 'ScreenRecording_09-17-2026 23-56-50_1.MP4' -t 4 \
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
