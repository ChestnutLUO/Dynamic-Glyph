# Portal level for gear drops

Status: PL1–PL2 implemented behind “Read gear drops (test)”; PL3 field test
pending. Companion to [gear-drop recognition](https://github.com/szres/dynamic-glyph-assets/blob/main/Docs/GEAR_DROP_RECOGNITION.md) (in the private test-assets repository).

Each hack's gear record carries the hacked portal's level, with a confidence
and every source that decided it. The level is never inferred from the items
that dropped.

## Sources

| Source | Where | Gives | Strength |
|---|---|---|---|
| Resonator labels | Portal screen, two columns of four `L1`–`L8` | All eight read: exact level, the sum over eight rounded down with an empty slot as zero. Fewer: a range, since an unread slot may be empty or L8. | Strong |
| Level badge colour | Portal screen, top left | One level for calibrated hues, a range otherwise | Medium |
| Glyph count | The hack itself, from the presentation tracker | L1: 1, L2: 2, L3–L5: 3, L6–L7: 4, L8: 5 | Weak (a range) |

Each source gives a set of levels; the estimate keeps the levels they share.
The Glyph table was validated on complex hacks, so a count from a hack whose
presentation command wasn't resolved is unreliable
(`HackCommandSummary.settlesGlyphCount`). Then the count never narrows the
level: if it contradicts the other sources it still flags the conflict, as
before, and the strongest source's range is kept; otherwise it is left out.
The uncalibrated badge range warmer than L5 (L1–L4) doesn't narrow it either.
The resonators, the calibrated hues and the L7 band narrow it as before, and
the count and the badge read stay in the estimate. An L7 portal with 3
Glyphs, an unread command and a badge read as L1–L4 had come out as L3–L4
(2026-10-27); it now comes out as L1–L7, from its one read resonator.

- One level left: **high** confidence when an exact resonator read and at
  least one other source agree; **medium** with an exact resonator read alone,
  or an exact badge that another source agrees with.
- Several left: a range with **low** confidence.
- None left: the strongest source's value, marked **conflict**, low
  confidence. Every source is logged, so conflicts can be reviewed in reports.

## Findings from the recordings (PL0)

- The order before a hack is: map, portal screen (0.25–2.5 s), a command
  screen where the player draws command Glyphs (chips such as “COMPLEX HACK”
  and “NO KEY”), then the presentation. The presentation tracker's hack start
  is 1.5–4 s after the portal screen.
- All 11 readable hacks in field tests 1 and 2 match the Glyph-count table.
  All were complex hacks: the player drew the complex command every time. A
  normal hack has not been checked; the label is not read yet.
- Resonator labels fade in with the screen, so often only one frame of two is
  readable. OCR reads labels with an agent name beneath them better than
  labels on enemy portals, which have none.
- Badge hues, the same on two phones: L8 258–260°, L6 328–330°, L5 343–344°.
  A fading badge has too few coloured pixels and is reported unread. L7 and
  L1–L4 are not calibrated: L7 is taken as the band between L6 and L8, and
  anything warmer than L5 as L1–L4.
- Portal screens have resonator bars at both edges, in pairs at the same
  height, about 5% of the height each, in the portal's faction colour:
  Resistance blue about (40, 105, 145), Enlightened green about
  (30, 80–186, 20–47), Machina red about (146, 0, 0). No other screen in the
  recordings has two such pairs; portal beams on the map can light one edge,
  and Machina beams carry blue (143, 18, 43). Until 2026-10-05 only blue was
  looked for, so Enlightened and Machina portals got no screen and no level
  from it.
- A neutral portal has no resonators, so no bars: its screen is not found
  this way, and no recording has one yet.
- Vision reads L1 labels as `L7` or `17` (13 of 57 L1 labels across 114
  portal screens, on Resistance and Machina portals alike). A label whose
  L is mostly L1's yellow (hue 50–78°, at least 60% of its 20 or more strongly
  coloured pixels, sampled from Vision's box for that character) is read as
  L1. On those 114 screens it changed exactly the 13 misreads and no other
  label.

## Design

- `PortalScreenDetector` (paired bars in one faction's colour, decoded band
  only; it names that faction, kept as `faction` in the screen's evidence and
  its `portalScreen` log row) and
  `PortalScreenReader` (OCR of the two label columns, 2× enlarged; badge hue)
  read the portal screen. Agent names beside the labels are never parsed,
  logged or stored; only `L` and a digit count.
- The shared OCR lane gets a `portal` mode at up to 5 Hz, never during a
  presentation or input and never over a result or gear panel.
- `PortalLevelObserver` keeps the fullest read of one screen fading in
  (reads within 1.5 s), and the newest screen otherwise. At the hack's start
  it hands that screen to the hack if it is at most 10 s old, then forgets it.
  A different known faction replaces the screen immediately, even with fewer
  or no readable labels. A replacement also clears the old badge. Out-of-order
  reads and late reads taken before the last hack started are discarded.
  This association is temporal: an entirely missed intervening portal screen
  can leave the previous screen within the window. No portal identity is kept,
  and the level's confidence does not measure association certainty.
- The Glyph count is recorded during input. The estimate is made when the
  hack's gear record is delivered, saved in it (`portalLevel`, optional so
  older gear still opens) and logged in `gear-drops.jsonl` as `portalScreen`
  and `portalLevel` rows.
- The card's Gear section shows the level, “Portal L6”, or a range such
  as “Portal L6–L7”, and “Portal level not read” when no source gave one.
  When the hack's portal screen was read, its faction follows in its colour,
  “Portal L6 · Resistance”, named as the English game names it. The estimate
  keeps it as `factionCode`, saved with the hack's gear; a hack without a
  portal screen shows none. The
  confidence stays in the logs; “Check against the panels” shows each source.

## Milestones

- **PL0** Recording check: done, above.
- **PL1** Package and replay: detector, reader, rules, observer, scheduler
  mode, `glyph-replay --gear` reports `portalLevels`; masked fixtures (only the
  bar columns and the badge).
- **PL2** App: live reading, gear record, log rows, card display.
- **PL3** Field test: slow and fast hacks, a normal (not complex) hack, a
  portal with empty resonator slots, a drone hack.

## Still open

- Whether a normal hack's Glyph count differs from a complex one's. Reading
  the command chips would let the rule account for it.
- Calibrating the badge for L7 and L1–L4.
- The drone view's header digit as a strong source for drone hacks.
- Better OCR of labels without an agent name. Each label's L is drawn in its
  level's colour; only L1's yellow is used so far. The other levels'
  colours are distinct on a dark backdrop (L4 3–12°, L5 339–345°, L6
  323–327°, L7 275–281°, L8 252–259°) but a blue or green backdrop shifts the
  sampled hue by up to 100°, so they don't correct a read yet.
