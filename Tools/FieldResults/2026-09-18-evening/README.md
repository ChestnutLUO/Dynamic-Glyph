# Second live field report: display surfaces

Source: `spikeB-2026-09-18T20-00-22Z` at the repository root, 163.7 seconds with
the Picture in Picture window, a Live Activity and debug video recording all
running. The raw folder is 110 MB and is not committed; the recording receipt is
kept here as [recording.json](recording.json).

This is the first run with the sequence display on a phone. It produced one
unambiguous success, one clear cause for every capture gap, and four concrete
defects that this report's changes address.

## The tracker collected a full sequence

Between 136.6 s and 139.6 s, with the window at the bottom of the screen:

| Slot | Glyph | Boundary that closed it |
| --- | --- | --- |
| 1 | forget | indicator advanced to slot 2 |
| 2 | attack | indicator advanced to slot 3 |
| 3 | see | indicator advanced to slot 4 |
| 4 | distance | indicator advanced to slot 5 |
| 5 | harmony | presentation ended, player input began |

Five slots, every one committed on a verified indicator transition, frozen at
input. The phase change into input came through the retained path, meaning the
countdown bar carried it while the header reader was behind — the behaviour
added after the previous report.

## Every capture gap was in the foreground

| | first 95 s (app frontmost) | after 95 s (backgrounded, window up, recording on) |
| --- | --- | --- |
| Recognition median | 25.40 ms | **10.66 ms** |
| Recognition p95 | 158.19 ms | **16.99 ms** |
| Capture gaps | **20 gaps, 30.74 s lost** | **none** |

All 20 gaps, including one of 6.17 s that destroyed a presentation, happened
while the app was in front. Backgrounded — the configuration that matters — the
pipeline ran comfortably inside its 50 ms sampling interval.

The cause was the app's own interface: the engine republished its state at 20 Hz,
rebuilding the whole view, and every captured sample buffer was handed to the
main actor for work that runs once every five seconds. Both are fixed; the
interface now refreshes five times a second and a buffer crosses only when a
JPEG is actually wanted.

A tempting alternative explanation was tested and rejected: the recognition log
is flushed to disk every 20 samples, but slow samples fall on a flush boundary
3 times in 50, which is exactly chance.

## The recorder did not get in the way

2622 frames over 163.7 s, 68.6 MB, **0 dropped for a full pool, 0 for rate, 1
not ready**, clean finish. 2623 recognition samples against 2622 recorded
frames, so the video holds what the recognizer analysed. Memory 59 → 79 MB,
thermal nominal to fair.

This is not an A/B against a run with recording off, so it shows the recorder
kept up, not that it costs nothing.

## The indicator reader is not the weak point

Across the whole run, 292 of 2623 samples yielded a strip reading and 1909 were
rejected as `inconsistentMarkerWidths` — but that denominator is mostly map and
menu screens with no strip at all. Restricted to the phases that matter:

**During presenting and input, the strip read on 211 of 224 samples (94%), and
all 13 failures were exactly the frames where the window overlapped the header.**

Obstruction, not recognition, is what costs slots. The tracking log shows it
directly: at 114.5 s the window sat over the array, four frames were refused
with `overlay covered the array`, and slot 4 closed as missing.

## What the run measured about the surfaces

- `pip: render size 189x106`. The canvas was 512×288, so everything drew at
  0.37 scale: names at 14 pt became 5 pt. The canvas is now 384×96 and carries
  one row of diagrams, a current-slot outline and a status colour — no text.
- The overlay marker was found in 531 frames and overlapped the header in 495 of
  them. It is detected only in the regions that are read, so this counts frames
  where the window was in the way, not frames where it was on screen.
- The Live Activity did not follow the sequence. Three causes, all fixed: the
  minimal presentation drew a fixed hexagon, updates inside the throttle window
  were discarded rather than held, and the payload had no input-slot index.
- The Picture in Picture window had the same fault from a different direction:
  its redraw key was built from the tracker's revision, and the revision only
  moved when the tracker made a decision. The indicator advancing during input
  is a reading, not a decision, so nothing downstream ever learned.

## Still unmeasured

Whether the strip layout is legible in the window iOS actually grants a 4:1
source; whether the minimal Island presentation is what the system chooses while
the screen-recording chip is present; and whether recognition timing moves at
all with recording off, which needs the paired run the checklist asks for.
