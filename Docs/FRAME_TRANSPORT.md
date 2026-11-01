# Frame transport — broadcast extension to app

On iOS 18–26 frames come from a ReplayKit broadcast upload extension, a
separate process. The app still runs recognition, OCR, results and the
displays, as it does with ScreenCaptureKit, so each frame the extension
receives has to cross into the app. This is the protocol for that crossing.
`FrameRing` implements it.

## What crosses

A **downsampled full-colour frame**, in the biplanar full-range 4:2:0 format
iOS captures in (`420f`), at about the size ScreenCaptureKit is asked for
today (603 × 1311 on an iPhone 17 Pro).
Colour is required: the slot indicators are told apart by colour
(`SlotStripReader`), and the header, result and gear readers use regions
outside the Glyph array. The app wraps the planes back into a
`CVPixelBuffer`, so the grayscale conversion the tests pin is unchanged.
Sending luma or selected regions only is an optimisation to consider after
measuring, not a starting point.

The extension scales to 603 pixels wide, the width recognition's layout
and thresholds were measured at, and never scales up. ReplayKit does not
deliver the screen's full size: an iOS 26 phone delivered 886 × 1918, which
halving would have left at 443 wide.

Frames are throttled to 20 Hz in the extension, before copying, as
`LiveGlyphOutput` throttles today.

## The shared file

One file, `FrameTransport/ring-v1` in the App Group container, mapped
`MAP_SHARED` by both processes. Its size is fixed by the header's slot count
and capacity. All integers are native-endian (both processes run on the same
device). Fields marked *atomic* are accessed only through atomic loads and
stores; everything else in a slot is protected by that slot's sequence.

### Header — 256 bytes

| Offset | Field | Writer | Meaning |
|---|---|---|---|
| 0 | `magic` u32 | producer | `DGFT` |
| 4 | `version` u32 | producer | 1 |
| 8 | `slotCount` u32 | producer | |
| 12 | `slotCapacity` u32 | producer | Payload bytes per slot |
| 16 | `producerSession` u64, atomic | producer | Random, non-zero, new for every broadcast; 0 = none |
| 24 | `producerState` u64, atomic | producer | 0 idle, 1 running, 2 paused, 3 finished, 4 failed |
| 32 | `producerHeartbeat` u64, atomic | producer | Uptime (ns) of the producer's last sign of life |
| 40 | `published` u64, atomic | producer | Frames published this session; the next frame's sequence |
| 48 | `overwrittenUnread` u64, atomic | producer | Frames overwritten before the consumer read them |
| 56 | `producerDropped` u64, atomic | producer | Frames not published at all, e.g. larger than a slot |
| 64 | `consumerSession` u64, atomic | consumer | The session the consumer has acknowledged |
| 72 | `consumerRead` u64, atomic | consumer | The next sequence the consumer wants |
| 80 | `consumerHeartbeat` u64, atomic | consumer | Uptime (ns) of the consumer's last read or poll |
| 88 | `stopRequested` u64, atomic | consumer, widget extension | The session the app or the Control Center switch asks the producer to end; 0 = none |
| 96 | `producerPeakFootprint` u64, atomic | producer | The extension's peak memory footprint so far, bytes |
| 104 | `producerEndReason` u64, atomic | producer | 0 none, 1 ReplayKit finished the broadcast (the player or iOS), 2 the app asked |

### Slots

Slot `i` starts at `256 + i × stride`, where `stride` is a 128-byte slot
header plus `slotCapacity` rounded up to 64 bytes.

| Offset | Field |
|---|---|
| 0 | `sequence` u64, atomic: 0 empty; `2n+1` while frame `n` is written; `2n+2` once it is complete |
| 8 | `session` u64 |
| 16 | `presentationTime` f64: the sample's timestamp, seconds on the host clock |
| 24 | `arrivalUptime` u64: when the producer received it, uptime ns |
| 32 | `width`, `height`, `pixelFormat`, `orientation` u32 each (orientation 0 = not reported) |
| 48 | `planeCount` u32 (1 or 2), `payloadLength` u32 |
| 56 | per plane (2 × 16 bytes): `offset`, `bytesPerRow`, `width`, `height` u32 each |
| 88–127 | reserved |

## Clocks

Every *uptime* is `ProcessInfo.systemUptime` in nanoseconds. It reads the same
clock in every process, so either side can age the other's timestamps against
its own. `presentationTime` is the sample's own timestamp on the host time
clock, which recognition uses as it uses ScreenCaptureKit's today.

## Publishing (producer)

For frame `n` = `published`, into slot `n mod slotCount`:

1. If the frame is larger than a slot, count it in `producerDropped` and stop.
2. If `n − consumerRead ≥ slotCount` and the consumer has acknowledged this
   session, the frame about to be overwritten was never read: count it in
   `overwrittenUnread`.
3. Store `sequence = 2n+1`, then a release fence.
4. Write the slot's fields and planes.
5. Store `sequence = 2n+2` with release ordering, then `published = n+1`.
6. Refresh `producerHeartbeat`, and post the Darwin notification
   `org.szres.DynamicGlyph.frames`.

## Reading (consumer)

For the next wanted sequence `m`:

1. Load `published` (acquire). Nothing new if `m ≥ published`.
2. If `published − m > slotCount`, the frames in between are gone: count
   them as missed and move `m` to `published − slotCount`.
3. Load the slot's `sequence` (acquire). Anything but `2m+2` means frame `m`
   was overwritten or is being overwritten: count it as missed and move on.
4. Copy the fields and planes out: the planes straight into a pixel buffer
   from the consumer's pool.
5. Acquire fence, then load `sequence` again. If it changed, the copy may be
   torn: discard it, count it, and move on.
6. Check the copy: its session is the header's, its dimensions and plane
   layout fit the slot. A frame that fails is rejected, never repaired.
7. Store `consumerRead = m+1` (release) and deliver the frame.

A single latest-frame slot would lose the ~100 ms blank between two Glyphs
whenever the app is late, which is why this is a ring. The consumer copies
frames out on a thread of its own as soon as it is told there is one, so the
ring only has to cover that thread's latency, not OCR. Every loss is counted
(`overwrittenUnread` on one side, missed and torn on the other), and each
lost frame breaks continuity for recognition exactly as a ScreenCaptureKit
stall does.

## Sessions, start and stop

- **Start.** The producer creates the file if it is missing or incompatible
  (magic, version, slot count or capacity). Otherwise it reinitialises it in
  place, and never replaces it: the consumer's mapping would keep pointing at
  the old file. In order: `producerState` idle, `published` 0, every slot's
  `sequence` 0, a new `producerSession`, then `producerState` running. The
  session goes last, so a consumer that sees it also sees everything reset.
- **Acknowledgement.** The consumer stores the session it is reading as
  `consumerSession`. Until it does, the producer counts nothing as
  overwritten-unread: nobody was reading.
- **Session change.** A `producerSession` different from `consumerSession`
  is a new capture: the consumer starts again from sequence 0 and reports a
  break in continuity.
- **Stop from the app.** The app cannot end a broadcast. It stores the
  session in `stopRequested` and posts `org.szres.DynamicGlyph.stop`; the
  producer reads the field and ends the broadcast. A notification only
  prompts a read: the state in the file is the truth.
- **Stop from Control Center.** The Control Center switch stops a broadcast
  the same way, from the widget extension, so it ends even while the app is
  suspended. The producer records `stopRequested` as its end reason; an app
  still attached takes that as the switch's stop, not an interruption.
- **Heartbeat age.** Uptime restarts with the device, so a
  `producerHeartbeat` more than 250 ms ahead of the reader's clock was left
  before a restart and counts as infinitely old, never fresh. Readers read
  the heartbeat before taking the time, so a write between the two can only
  make it look older.
- **End.** The producer stores `finished` or `failed` in `producerState`.
- **Replaced file.** If the file's inode differs from the one mapped (the
  producer had to recreate it), the consumer maps it again.

## What the consumer reports

Three separate things, because they fail separately:

| | Signal | Meaning for recognition |
|---|---|---|
| Image evidence | New frames | Analysed as today |
| Producer health | `producerHeartbeat` age | Stale means the extension stopped executing: the display expires its guidance |
| Capture interruption | `producerState` paused, finished or failed; a session change; frames missed or torn | Continuity breaks, as for a ScreenCaptureKit interruption |

A quiet ring with a fresh heartbeat is **not** a still screen: whether
ReplayKit stops delivering on a still screen is a Phase 0 measurement, not an
assumption. Until it is measured, a quiet period keeps prior observations but
refreshes none of their evidence times.
