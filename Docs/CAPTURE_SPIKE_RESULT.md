# Spike B — result: PASS

Run `spikeB-2026-09-18T05-51-24Z`, iPhone 17 Pro, iOS 27.2.

## Verdict

**iOS vends another app's pixels, un-redacted, and keeps delivering them while
the capturing app is backgrounded.** Saved JPEGs from the backgrounded window
show live Ingress — scanner map, portals, links, drone view with its own
controls and timer. Not black, not a placeholder, not a frozen frame of the
spike. Architecture A is alive.

| Criterion | Target | Result |
|---|---|---|
| JPEGs containing Ingress | ≥10 | 5 of 5 from the backgrounded window ✓ |
| `complete` frames while backgrounded | ≥80% | **100%** (1561/1561) ✓ |
| Live content, not a frozen frame | hash varies | 484 distinct hashes over 26 s ✓ |
| No `didStopWithError` | none | none ✓ |
| Memory | stable | 29.0 → **21.7 MB** (fell) ✓ |
| Thermal | ≤ fair | nominal throughout ✓ |

Delivery while backgrounded: 1561 frames over 26.1 s = **59.8 fps**, median
inter-frame gap 17 ms, p99 29 ms, max 103 ms, zero gaps over 250 ms.

## What the run taught us that the headers did not

1. **~60 fps, and it cannot be turned down.** `minimumFrameInterval` is
   `API_UNAVAILABLE(ios)`, and iOS delivers at display rate. At 603×1311 that is
   roughly 118 MB/s of YUV arriving whether we want it or not. **Frame dropping
   in the output handler is mandatory, not an optimisation.**
2. **Pixel format is `420f`** — biplanar full-range YUV 4:2:0. This is good news
   for recognition: plane 0 is luma, so thresholding needs no colour conversion.
   It is still not selectable, so handle it rather than request it.
3. **41% of one core** was spent on nothing but a 64-bit difference hash and one
   CSV row per frame, at 60 fps. Per-frame recognition is unaffordable; the
   adaptive sampling in the plan is load-bearing.
4. **`videoOrientation` is never populated.** All 3236 frames reported no value
   despite the key existing on iOS 27. Either it appears only on rotation or it
   is not delivered on iOS. **Open question — needs a deliberate rotation test.**
5. **Three different coordinate spaces.** The filter reported `contentRect`
   402×874 pt at `pointPixelScale` 3.00; the stream was configured 603×1311; the
   per-frame `contentRect` came back 201×437. Derive the ROI from the delivered
   buffer dimensions, never from the filter's rect.
6. **Self-capture is confirmed.** The Dynamic Island — including the red capture
   indicator — is plainly in frame. The top-band crop the plan calls for is
   required, not precautionary.

## Bonus: the glyph array was captured, and it solved Deliverable 3

Two of the five backgrounded frames are a live glyph hack.

- **`frame-02389.jpg`** — the "Incoming glyph sequence" screen: four hexagons
  (a four-Glyph sequence, so an L6–L7 portal) above a clean, unobstructed
  eleven-node array on black. As good a calibration frame as could be asked for.
- **`frame-02690.jpg`** — the input phase: "GO!", a 14:62 countdown, Glyph 2 of
  4 highlighted, and a stroke mid-draw.

From the first, `Tools/detect-nodes.swift` recovered all eleven node centroids.
Normalised within the array's bounding box the lattice is exact:

    x ∈ { 0, ¼, ½, ¾, 1 }        y ∈ { 0, ¼, ⅜, ½, ⅝, ¾, 1 }

The labelling — which physical node the data set calls `0` — was then inferred
as reading order, top to bottom then left to right, and confirmed three
independent ways: `clear` = `05a` is the vertical axis; `all` = `018a920` is the
closed outer hexagon using every vertex and no inner node; and `clear_all` is
byte-for-byte `all` + `clear`. All three are now tripwire tests in
`NodeArrayTests`.

**The second frame also previews the trail question.** The stroke shows a bright
head with a decaying tail rather than a uniformly lit path, which points at the
harder of the two cases in the plan — order may have to be reconstructed from
per-pixel time-of-first-ink rather than read off a single frame. One frame is
not enough to settle it; Task 0 still owes us a proper answer.

## What is still unproven

- **Long-run stability.** The backgrounded windows were 16 s and 26 s, not the
  15–20 minutes the protocol asks for. Thermal behaviour, memory over a real
  session, and whether iOS eventually tears the stream down are all untested.
- **The trail-fade model**, as above.
- **Whether node detection survives a cluttered background.** The calibration
  frame is the glyph screen, which is near-black. The input phase already shows
  a portal glow bleeding into the array region.
