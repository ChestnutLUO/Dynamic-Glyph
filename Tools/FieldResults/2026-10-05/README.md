# One-Glyph hacks and other factions' portals: the October 5 field test

Reviewed the private report `DynamicGlyph-spikeB-2026-10-05T21-17-33Z`, 8½
minutes with a screen recording, from a build at or after beta 0.1.0-3. The
tester, a Resistance player, noted "Hack with different faction". The raw
report is extracted outside the checkout; only masked fixtures enter the
repository.

## What the build read

| Video | Hack | What the game showed | What the app read |
| --- | --- | --- | --- |
| 0:11 | Glyph, 4 Glyphs, L6 Resistance portal | 120% / 80%, Complex, No key | the same; 13 items, both panels |
| 1:32 | Glyph, 1 Glyph (PURE), L1 portal | 38% / 96% | **no hack**; its 7 items saved as an unclaimed drop |
| 2:56 | Glyph, 1 Glyph (BALANCE), L1 Machina portal | 38% / 92% | **no hack**; its 7 items saved as an unclaimed drop |
| 4:44 | Glyph, 5 Glyphs, L8 | 163% / 65% | the same; 13 items, both panels |
| 5:24, 6:28, 6:43, 8:12 | ordinary hacks; 6:28 follows an Enlightened portal's screen | portal panel only | four portal-only drops, items as shown |

Every drop group's rows were read in full and none arrived late. The red
"Portal running hot. Cooldown…" banners were taken for command notices about
80 times and dropped as unreadable, which only adds log noise.

## 1. A one-Glyph strip was never read

`SlotStripReader` required at least two indicators (`tooFewMarkers`), so a
level 1 portal's one-Glyph hack could not start. The floating window's edge
crossed the strip, so every frame was logged as `coveredByOverlay` (samples
1864–1924 and the hack at 2:56), though the 4- and 5-Glyph strips read with
the window in the same place. The tracker then saw input reappear with no
presentation and took it for hack 1 returning.

Fix: a single indicator is accepted under the same width and full-height
checks, and only at the screen's centre, where the game draws a one-slot strip
and no marker left from a longer row sits. Fixtures `Fixtures/Assets/Screenshots/OneGlyph`.

## 2. A one-Glyph result's 38% read as "З8%"

On the reader's crop at capture size, Vision returned `З8%` with a Cyrillic
Ze on every frame of the PURE result; the parser rightly refused it. 1.5 times
the size reads `38%`, but enlarging every read lost short stage names (XM
on `four-final.png`). The reader now takes one second look, enlarged, only
when a value line ends in `%` with a look-alike in it, and keeps the stage
name from capture size. Fixture `Fixtures/Assets/Screenshots/Results/one-final.png`.

## 3. Only blue portal screens were found

`PortalScreenDetector` looked for blue resonator bars, measured on Resistance
portals. The Enlightened screens at 36, 278, 303.5 and 377–382 s and the
Machina screens at 168–173 and 446–487 s were never detected, so those hacks
got no screen level. The bars are drawn in the portal's faction colour:

| Faction | Bar colour, at 301 px wide |
| --- | --- |
| Resistance | about (40, 105, 145) |
| Enlightened | about (30, 80–186, 20–47) |
| Machina | about (146, 0, 0) |

The detector now takes pairs in any of the three colours and names the
faction; the screen's evidence and its `portalScreen` log row carry it. A scan
of all 35 recordings at 2 frames per second, before and after: green and red
pairs appear only on Enlightened and Machina portal screens (this report and
2026-09-25T01-56-13Z, 2026-09-27T05-31-09Z), the blue count is unchanged,
and the map with Machina beams (143, 18, 43) and pink or magenta screens no
longer match. Fixtures `Fixtures/Assets/Screenshots/PortalLevel/enlightened-*`, `machina-*`,
`map-machina`.

No recording shows a neutral portal's screen. It has no resonators, so no
bars, and isn't found this way; it needs a recording first.

## Replays, before and after

Each recording replayed through `glyph-replay` (live results, gear and
commands) with the build before these changes and after them:

| Recording | Before | After |
| --- | --- | --- |
| this report | 2 hacks; groups 2 and 3 unclaimed; 70 portal reads, no faction | 4 hacks, all complete: PURE 38% / 96%, BALANCE 38% / 92%; groups 2 and 3 ordered to them; portal reads 70 Resistance, 20 Enlightened, 55 Machina |
| `2026-09-27T05-53-12Z` | no hack | 1 hack, MYSTERY 38% / 89%, another one-Glyph hack that was missed |
| `2026-09-28T20-50-18Z`, `2026-09-28T01-41-12Z`, `2026-09-23T23-00-56Z`, `5Glyphwitherrorglyphandredo`, `2026-09-29T18-27-50Z`, `2026-10-02T18-06-56Z` | — | the same hacks, results, gear groups and portal levels; their portal reads are now labelled Resistance, the same counts |

## 4. Machina labels now read, and one misreads

Reading Machina portal screens for the first time exposes the label reader:
on the screen before BALANCE, every label shows **L1** (a yellow L, a white 1),
but Vision reads some as `17`, which the parser's rule for a whole label read
as digits ("18" for L8) takes as L7. The screen gives [1, 1, 1, 1, 1, 1, 7, 7],
an average of L2, against the one Glyph's L1: the hack gets **L2, low
confidence, conflict**, where before the screen was never read and the Glyph
count alone gave L1. Not changed in that commit; fixed after it by the
label's colour: an L1 label's L is yellow, which no other level's is (see
`Docs/PORTAL_LEVEL.md`). The same misread also hit a Resistance L1 portal on
2026-09-26.

### Review validation (2026-10-08)

A local Vision probe of the label-column image read seven labels on this
Mac: six L1 and one L7 before the colour rule, seven L1 afterward. With the
one-Glyph count, the estimate changed from L1 / low confidence to L1 / high
confidence, with no conflict. This cropped probe does not reproduce the
full-frame L2 estimate above or establish eight-label OCR coverage.

The repository regression pins those seven OCR readings, the colour rule and
the final high-confidence, conflict-free estimate. The screenshot is excluded
from this change because it still contains map fragments; it remains private.

## What this doesn't show

- The faction is read and logged, not yet saved with a hack or shown: storing
  it, the player-faction setting and split statistics are the separate
  faction plan.
- A hack made without the portal screen just before it has no screen, so no
  faction or screen level. Ordinary hacks have no Glyph count either.
- Vision on the phone may read the 38% differently from the Mac; the second
  look is unmeasured on a device, as is its cost there.
- Two-Glyph hacks are still unrecorded.
