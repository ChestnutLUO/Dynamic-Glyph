# Spike B — live Glyph display field test

## What this target does now

Requires **iOS 18+**: iOS 27 captures through ScreenCaptureKit, iOS 18–26
through a ReplayKit broadcast, where the floating window must stay open. It
captures the screen, recognizes Glyph shapes at up to
20 Hz, classifies the game phase from the header text, tracks the presentation
slots from the indicator strip, predicts the rest of the sequence from the
sequence table, and shows the result in a Picture in Picture window and,
optionally, a Live Activity.

What it does **not** do: capture sound for Photos recordings on iOS 18–26,
Dynamic Island–only display on iOS 18–26, and any claim about sustained device
behaviour that has not been measured on a phone. See *Status of the evidence*
at the end.

On iOS 18–26, Start opens the system's broadcast sheet: tap **Start
Broadcast**, then wait out the three-second countdown. To stop, use Stop in
the app; iOS then shows that Dynamic Glyph stopped watching the screen.
That sheet tells the app nothing when it is closed without starting. The
Start button reads **Cancel** while the app waits; tap it, or the app gives up
by itself after 30 seconds. A broadcast that begins within 10 seconds after
that is ended, so nothing keeps sharing the screen unwatched. While it waits,
the session log records each time the app becomes inactive or active.

## Set up the tables

Two runtime inputs, both read from the app's Documents folder at launch. They
are inputs, not bundled data.

| File | Needed for | If missing |
| --- | --- | --- |
| `glyph_line.csv` | Shape recognition | Capture cannot start |
| `glyph.csv` | Sequence prediction | Everything else still works; the display says `Prediction unavailable` |

Copy both to the device once, replacing `YOUR_DEVICE_ID` with the identifier
from `xcrun devicectl list devices`:

```sh
xcrun devicectl device copy to --device YOUR_DEVICE_ID \
  --source Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/glyph_line.csv \
  --destination Documents/glyph_line.csv \
  --domain-type appDataContainer --domain-identifier org.szres.DynamicGlyph

xcrun devicectl device copy to --device YOUR_DEVICE_ID \
  --source Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/glyph.csv \
  --destination Documents/glyph.csv \
  --domain-type appDataContainer --domain-identifier org.szres.DynamicGlyph
```

**Settings → Glyph data** then shows `142 Glyph shapes loaded` and `540
sequences (542 rows, duplicates merged)`. **Add shape list…** and **Add sequence
list…** there are a fallback for AirDropped files; no import is needed when the
Documents copies are present. Without a shape list the home screen shows a
one-time setup card instead of enabling **Start**.

The first launch, and every launch until it is finished, opens a guided
setup: welcome, the account warning from the README, the Dynamic Island
(skipped on models known to have none; asked about on models newer than the
app's list), a Live Activities tip when they are off, the floating window's
shape and sharpness on ticked sliders under an animated preview, and the shape
list (skipped when already loaded). The floating window can be turned off only
once the Dynamic Island is chosen and Live Activities are on, so setup never
finishes with nothing to show the sequence. **Settings → Run setup again**
repeats it.

If the sequence table names a Glyph the shape table does not have, the app says
so on the sequence status line rather than predicting it.

## Build and install

```sh
cd Apps/DynamicGlyph && xcodegen generate
open DynamicGlyph.xcworkspace
```

Select the phone and run the `DynamicGlyph` scheme, which builds **Release**
for field performance. The project now has two targets: the app, and the
`GlyphWidget` WidgetKit extension that draws the Live Activity.

Command-line signing may fail with `errSecInternalComponent` when the login
keychain is locked to a non-interactive shell. Unlock it in a terminal
(`security unlock-keychain`) or build once from Xcode; an unsigned compile check
is always available:

```sh
xcodebuild -project Apps/DynamicGlyph/DynamicGlyph.xcodeproj \
  -scheme DynamicGlyph -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/DynamicGlyphDisplayBuild CODE_SIGNING_ALLOWED=NO build
```

## Field procedure

1. Launch the app. Confirm both table status lines under **Settings → Glyph
   data** without importing anything.
2. Tap **Start** and choose the whole display. Rendering starts
   only after capture is running, so the consent sheet and the Picture in
   Picture window never compete for the screen.
3. Tap **Show floating window** under **Show the sequence in**. The window is a strip:
   one row of Glyph diagrams, the current slot outlined, a colour along the
   bottom edge for state, and no text. The device gave it 189 x 106 points for
   the old 16:9 canvas, at which every word on it was unreadable. Check the inline preview
   is showing content first — the window cannot open from a blank layer.
   Turn on **Settings → Floating window → Open when you leave the app** if you
   want it to appear by itself when you switch to the game.
4. Optionally turn on **Dynamic Island**. The **Floating window**, **Dynamic
   Island**, **Open when you leave the app** and **Hide from screenshots**
   switches, **Save logs and screenshots**, and the window's shape, are
   remembered across launches; screen recording is not.
5. Tap **Open Ingress** (it appears once capture is running). If the floating
   window is not set to open by itself it is opened first, then the game is
   launched through its `link.ingress.com` universal link; without the game
   installed the App Store page opens instead. Keep the phone upright. Drag the Picture in Picture window
   to a corner clear of the Glyph array and the header. Play several hacks.
6. Return to Dynamic Glyph and tap **Stop**. This stops capture, rendering and
   any Live Activity. Closing the Picture in Picture window on its own only
   hides the display; capture keeps running and the window is not reopened
   automatically.
7. If **Settings → Bug reports → Save logs and screenshots** was on (it is off
   until you turn it on), open **Session logs and reports** in the same
   section, pick the session, read its event log, and tap **Share report…** to
   send the whole
   folder as a zip (AirDrop, Files, Mail). Finder → iPhone → Files →
   DynamicGlyph still works for the raw `spikeB-<timestamp>` folder. Old
   sessions can be deleted from the same list.

### Reading the window at a glance

The outer edge of the Picture in Picture window is a status colour, and it is
the outermost thing drawn on purpose: the window can be tucked against the side
of the screen so only a sliver shows, and that sliver is the edge. The colour is
readable when nothing else on the window is.

| Edge colour | Meaning |
| --- | --- |
| Grey | Nothing to show — no Glyph screen, or the command channel, or the phase could not be read |
| Cyan | Collecting the presented sequence |
| Violet | Your turn: the sequence is frozen and you are drawing |
| White | Glyph hack complete |
| Amber | Working, but not claiming a verified sequence — provisional shapes, or positions that could not be confirmed |
| Red | Do not trust what is shown — capture stopped, no new frames, indicators covered, or the slot count changed mid-hack |

There is no identifying border inside that edge. The window used to carry a
lime hairline so the app could find its own reflection in the capture; it was
removed, and with it the app's ability to tell its window apart from the game.
See [Self-capture and the window](#self-capture-and-the-window).

### While the game is in front

- During command entry the display says `Command channel · waiting for the
  sequence`. Command gestures are drawn on the same array with the same
  vocabulary and must never appear as slots.
- During the presentation, slots fill in left to right. A shape that is visible
  but has not crossed a boundary is captioned `Observing…`, not `Observed`.
- When the countdown starts, the sequence freezes. Your own strokes must not
  change any tile. This is the behaviour the whole feature exists for: check it
  explicitly.
- A slot the app could not read stays in place as `?` / `Missed`. Later Glyphs
  keep their positions; the sequence is never closed up.
- If the indicators are covered — by the window itself or by a notification
  banner — the status turns to `Slot row covered · move the window`, what was collected is
  kept, and nothing new is committed until they are readable again. Silence
  notifications with a Focus before a field run; a banner over the strip costs
  slots.
- The Dynamic Island shows the Glyph to draw now, and the next one where there
  is room. It shows nothing at all rather than a stale instruction: guidance is
  withdrawn when the indicator has not been read for 0.75 s, when the
  indicators are covered, when the slot count changed mid-hack, or when the
  display is only claiming provisional shapes.
- On phones where the screen-recording chip takes a place in the Island, the
  activity only gets the minimal presentation. There a ring with one segment
  per slot shows collection as it happens: lavender for a collected Glyph,
  amber for the one on screen, red for a lost slot, grey for slots not yet
  reached. The thick segment is the slot being seen, or during input the one
  being drawn. The centre holds the Glyph on screen, the Glyph to draw, or a
  yellow warning when the slot row is covered.
- The Island's keyline takes the Picture in Picture edge colour for the same
  status, in every presentation.

## What to inspect afterwards

A session folder is written only when **Save logs and screenshots** is on.
With it off, recognition and the displays run exactly the same, nothing is
saved, and none of the diagnostic work is done either: no per-frame hop to the
main thread, no picture hash, no log rows built, no Diagnostics readouts or
observation history, and no floating-window statistics timer. The Diagnostics
page says so; statuses and capture events still show.

**Hide from screenshots** sets `preventsCapture` on the floating window's
display layer. Screenshots and screen recordings, including this app's own
capture, should show the window as black. That the system honours it for the
Picture in Picture window, and what this app's recognizer then sees where the
window sits, still needs checking on a phone.

| File | Contents |
| --- | --- |
| `recognition.jsonl` | Schema **4**. Per sample: shape state, edges, candidates, ink counts, calibration, processing time, plus the tracked phase and its source, hack id, model revision, slot count and highlight, header text/confidence/source time, and header scheduler counters. Schema 3 also carried overlay detection, which no longer exists. |
| `tracking.jsonl` | Schema 1. One row per tracker decision: every commit, every refusal, the slot it concerned, the boundary reason and how many samples supported it. This is where a wrong sequence is diagnosed. |
| `snapshots.jsonl` | Save receipts and encoding time for the PNGs. A filename in `recognition.jsonl` is marked `queued`; the receipt is the proof it was written. |
| `glyph-*.png` | Lossless screenshots on observation changes, at most five a second and 400 a run. |
| `frames.csv` | Capture telemetry, now including a `pipActive` column. |
| `glyph_line.csv`, `glyph.csv` | The exact tables the run used. |
| `events.log` | Capture, Picture in Picture and Live Activity lifecycle. |
| `screen-recording.mp4` | Only when debug recording was on. H.264, up to 20 fps, capped at 10 minutes or 300 MB. The entire display, including this app's own Picture in Picture window. |
| `recording.json` | Schema 1. Why the recording stopped, how many frames were dropped and why, and `firstPresentationTime` — the one number that maps every `presentationTime` in the other logs onto the video. |

Useful checks:

```sh
# Every slot commit, with the evidence that allowed it.
python3 -c "import json,sys;[print(r['kind'],r.get('slotIndex'),r.get('glyph'),r['reason']) \
  for r in map(json.loads,open(sys.argv[1])) if r['kind'].startswith('slot')]" tracking.jsonl

# Processing time against the 50 ms sampling interval.
python3 -c "import json,sys,statistics as s;v=[json.loads(l)['processingMilliseconds'] \
  for l in open(sys.argv[1])];v.sort();print('median',s.median(v),'p95',v[int(len(v)*0.95)],'max',v[-1])" recognition.jsonl
```

## Keeping a recording in Photos

**Settings → Recording → Save a recording to Photos** records the next session
and adds the video to Photos when it ends: on **Stop and save to Photos**, on
**Stop**, or at 30 minutes or 1 GB. It is separate from **Record the screen**:
it needs no session logs, keeps nothing in the session folder, and either can
be on without the other; with both on, each encodes its own copy. Like that
switch it applies to one launch at a time and cannot change mid-session.

Turning it on asks for add-only access to Photos; the app never reads the
library. The movie is written to a private temporary folder and moved into
Photos. If Photos refuses it, it is moved to the app's folder in the Files app
as `DynamicGlyph-recording-<timestamp>.mp4` instead, and Settings says so. A
recording that failed or could not be finalized in time is reported, not
saved. It holds the same frames recognition analyzed, up to 20 a second, and
the whole display, as **Record the screen** does.

**Include sound** (remembered) adds the device's sound, such as the game's, as
an AAC track. The microphone is never recorded. Sound is captured only for a
session whose Photos recording actually started with it on, arrives on its own
queue, and is dropped rather than queued if the encoder falls behind; the
receipt counts `audioSamplesAppended` and `audioSamplesDropped`. A recording
with nothing playing is still a normal video.

## Producing a bug report

Turn on **Settings → Bug reports → Save logs and screenshots**, then **Record
the screen**, *before* starting a session. Recording needs the logs on, since
the video is saved in the same folder. It cannot be turned on mid-session, and
it is off again next launch.

> This records everything on the display, not just the game: notifications,
> messages, other apps, and anything you type. The video is saved unencrypted in
> the evidence folder, and anyone you send that folder to can watch all of it.
> Silence notifications and close anything you would not send to a stranger
> before you start, and watch the video yourself before sharing it.

The recording holds **the frames the recognizer analysed** — it is fed from the
recognition callback after the sampling throttle, not from a clock of its own —
so a time in the logs is a time in the video:

```sh
# Every tracker decision, at its position in screen-recording.mp4.
python3 -c "import json,sys; t0=json.load(open(sys.argv[1]))['firstPresentationTime'];   [print('%7.2f  %-16s slot=%s %s  %s' % (r['presentationTime']-t0, r['kind'],     r.get('slotIndex'), r.get('glyph') or '', r['reason']))    for r in map(json.loads, open(sys.argv[2]))]" recording.json tracking.jsonl
```

It stops by itself after 10 minutes or 300 MB, whichever comes first, and says
which in `recording.json`. That is shorter than the 15-20 minute field run this
document asks for elsewhere, on purpose: press **Stop recording** as soon as the
problem has happened, which finalizes a short attachable file while capture
keeps running.

A receipt exists from the moment recording starts, so a session interrupted by a
crash leaves `recording.json` with `"state": "recording"` rather than nothing.
The movie is written in fragments for the same reason — an interrupted file
still opens, up to the last complete fragment.

Send the whole evidence folder. The video is not a substitute for
`tracking.jsonl`; it is what makes it legible.

## Self-capture and the window

The app draws Glyph diagrams onto the screen it is recording, and the second
field run showed the Picture in Picture window does appear in the capture. That
is a direct feedback risk: a diagram of `see` over the game array is, to the
recognizer, a `see` on the array.

One defence remains: the window draws no hollow node rings. Rings are exactly
the cue the array detector locks on to; the diagrams use small filled markers
instead, so the app cannot calibrate onto a picture of itself.

The window no longer carries an identifying border, and the app does not look
for itself in the frames it captures. It therefore cannot tell when the window
covers the header, the indicators or the array, and it treats whatever it reads
there as the game's. Keep the window clear of the array, the header and the
indicator strip. The window's own gold and violet are the colours the strip
reader counts; its geometry checks usually reject such a strip, which the
tracker shows as `Slot row covered · move the window`, but nothing guarantees it.

## Device acceptance checklist

Not yet performed. Each line is a separate observation, not an inference from
the one above it.

- [ ] Both tables load at launch with no import.
- [ ] Capture starts, the window opens, and Ingress is still audible.
- [ ] The window survives backgrounding and does not freeze.
- [ ] A full hack: command, presentation, input, completion. The presented
      sequence is legible **while drawing**, and predictions are visibly
      distinct from observations.
- [ ] The window does not reopen after being dismissed.
- [ ] Drag, resize and tuck the window away, and place it over the array and
      over the header. Record from `tracking.jsonl` whether any slot was
      committed from the window's own diagrams or a fake boundary was created;
      nothing in the app prevents either.
- [ ] `frames.csv` has real rows, and the count agrees with the capture
      interval. The first field run logged none of this.
- [ ] A saved PNG exists for each presented slot, or the omission is in the log.
- [ ] Stop/start and a cancelled consent sheet leave no stale sequence.
- [ ] Close the sharing sheet without starting, then tap Cancel: Start is
      ready again at once. On iOS 18–26, also tap Cancel during the
      countdown: the broadcast that begins ends by itself within seconds.
      Note the `app inactive`/`app active` lines around the sheet in the log.
- [ ] 15–20 minutes, several hacks, game audio, app switches, Low Power Mode.
      Watch thermals, memory footprint and CPU in `frames.csv`.
- [ ] With the Live Activity on, measure how far the Island lags the Picture in
      Picture window, and record it. More than one activity — the system
      recording indicator is one — changes the space available.
- [ ] Retrieve the whole folder and annotate the presented slots independently,
      including frames the recognizer rejected.
- [ ] With debug recording on, `processingMilliseconds` and the complete/idle
      ratio in `frames.csv` are unchanged from a run with it off. A rise in
      `idle` is the signature of a starved capture stream.
- [ ] `framesDroppedPoolFull` and `framesDroppedNotReady` in `recording.json`
      stay near zero under real load.
- [ ] The video plays, shows the game, and shows the Picture in Picture window.
- [ ] Recording survives ten minutes in the background and stops itself cleanly
      at its cap while capture continues.
- [ ] Force-quitting mid-recording still leaves a playable file.
- [ ] The strip is legible in the window iOS grants a 4:1 source.
- [ ] The status edge is an even band all the way round, corners included,
      at the smallest and the largest window size. Its inner corners assume
      the window is rounded to 9 pt (`PiPCanvasConfiguration.windowCornerRadius`),
      measured from one capture of one window; a fat or thin band at the
      corners of another size means that number is wrong.
- [ ] With the screen-recording chip present (the minimal presentation on
      every phone before iPhone 18 Pro), the ring's segments are legible, fill
      as each Glyph is collected, and the centre follows the sequence.
- [ ] The Island keyline colour is visible and matches the window's edge
      through collecting, input, a covered slot row and a stale display.
- [ ] The paired run: one session with debug recording off and one with it on,
      comparing `processingMilliseconds` and the complete/idle ratio.

## Status of the evidence

| Claim | Established by |
| --- | --- |
| Shape recognition on real presentation pixels | 2026-09-17 recording validation, 28/28 annotated frames |
| Slot count and highlight read from pixels | Unit tests over two independent captures |
| Header phase read from pixels | Unit tests over six captured screens plus a map negative |
| Whole pipeline recovers a five-slot sequence | [Phase replay](../Tools/PhaseReplayResults/2026-09-18/README.md), 200 frames, no annotation in the loop |
| Tracker rules, including the ones hard to stage | 19 state-machine tests |
| Diagram orientation in the sample-buffer bitmap | Pixel test over a rendered bitmap |
| Compiles for iPhone, app plus widget extension | Unsigned Release build |
| **Runs on a phone** | **Nothing yet** |
| **The app's own window is not read as game evidence** | **Nothing — there is no exclusion; keep the window off the array and header** |
| **Latency, thermals, battery, Island visibility** | **Nothing yet** |
| Debug recording: admission, append, anchor, receipt | `DynamicGlyphTests`, against the real writer on an iOS simulator |
| Debug recording on a phone | 2622 frames, no drops under pressure, clean finish — [second field report](../Tools/FieldResults/2026-09-18-evening/README.md) |
| Sequence collected on a phone | Five slots from one hack, every one on a verified boundary — same report |
| **Strip legibility and Island presentation on a phone** | **Nothing yet** |

## Calibration behaviour

Calibration is acquired only from an empty array with all 11 rings. It is
reused during drawing, refreshed on later empty arrays, and invalidated by size
changes, unsupported orientation, interrupted timestamps, or eight seconds
without a verified empty array. `waitingForEmptyArray` does not mean the game
has left the Glyph screen — that is what the header reader is for. Missing
orientation metadata is accepted for portrait buffers, matching the original
Spike B captures; other known orientations are rejected.

The header and indicator regions are fractions of the delivered frame height,
measured from real captures and listed in `GameUILayout`. A frame whose fitted
array overlaps those regions is not the layout they describe, and the phase is
reported unknown rather than read from the wrong pixels.

## Known limitation: a deprecated rendering path

iOS 27 deprecates `AVSampleBufferVideoRenderer`'s direct enqueue in favour of a
receiver obtained from an `AVSampleBufferRenderSynchronizer`. The deprecated
calls are deliberate, and the build warnings are left visible rather than
silenced. The replacement changes the timing model from display-immediately to a
synchronizer timeline, and its interaction with
`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)` is
untested; the current path is the one Spike A demonstrated. Migrating it is
follow-up work with its own device test.

## Original capture experiment

**Questions, in order.** (1) Does iOS's content-sharing picker vend a filter
covering content this app does *not* own? (2) Is that content delivered
un-redacted? (3) Does delivery continue while we are backgrounded and Ingress
is foreground? All three were answered yes; see [capture results](CAPTURE_SPIKE_RESULT.md).

## What the SDK already told us

Verified from `iPhoneOS27.0.sdk` headers, so the spike does not need to
rediscover it:

- `SCShareableContent`, `SCDisplay`, `SCWindow`, `SCRunningApplication` are all
  `API_UNAVAILABLE(ios)` — no enumeration of anything.
- **Every** `SCContentFilter` initialiser is `API_UNAVAILABLE(ios)`. The filter
  is a read-only token from the picker exposing only `style`,
  `pointPixelScale`, `contentRect` and the mic/camera flags. There is no
  supported way to aim capture at a chosen app.
- `SCShareableContentStyleApplication` is `API_UNAVAILABLE(ios)` — display or
  window only.
- `SCStreamConfiguration.minimumFrameInterval` and `.pixelFormat` are
  `API_UNAVAILABLE(ios)`. **The frame rate cannot be requested and the pixel
  format cannot be chosen** — both are discovered at run time and logged.
- `SCStreamFrameInfoVideoOrientation` *is* available (iOS 27.0). This is the
  ScreenCaptureKit counterpart to ReplayKit's `RPVideoSampleOrientationKey`.
- `SCStreamFrameInfoDirtyRects` is `API_UNAVAILABLE(ios)` — no cheap
  change-region hint, so ROI tracking cannot lean on it.

See the [first live field report](../Tools/FieldResults/2026-09-18/README.md)
for the run that produced the recognition evidence and the telemetry and
screenshot bugs fixed after it.
