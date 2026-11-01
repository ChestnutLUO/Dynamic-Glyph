# Gear item vocabulary

Checked 2026-09-27. This is a name-recognition list, not a drop-rate table or a
claim that every listed item is available from every portal. Names require an
explicit quantity in a recognized item panel; inventory and reward screens
are not alternative inputs.

| Category | English panel names |
|---|---|
| Level 1–8 | Resonator, XMP Burster, Ultra Strike, Power Cube |
| Mods, without levels | Portal Shield, Aegis Shield, Force Amp, Turret, Heat Sink, Multi-Hack, Link Amp, SoftBank Ultra Link, ITO EN Transmuter (+), ITO EN Transmuter (-) |
| Other items, without levels | Portal Key, Hypercube, ADA Refactor, JARVIS Virus, Capsule, Kinetic Capsule |
| Event-dependent | Media (only the literal item label; arbitrary media titles remain unrecognized) |

The [official inventory glossary](https://support.ingress.com/hc/en-us/articles/41140354084123-Glossary)
supplies the main names. The [hacking guide](https://support.ingress.com/hc/en-us/articles/41140376184091-Hacking-Portals)
describes portal drops and keys. [Rare Kinetic Capsules](https://support.ingress.com/hc/en-us/articles/41140341728411-Kinetic-Capsules)
can be hacked; the Common version is claimed from the store. Its rarity still
comes from the meter. [Event Media](https://ingress.com/en/news/runningman-digital-release)
can also be hacked. Future event names require new evidence rather than fuzzy
matching to a familiar item.

Premium-only names such as Key Locker, Beacon, Fracker and Apex are not added
as normal hack drops. Retired Quantum/MUFG Capsules and old sponsored names
are not aliases for current items: [Quantum Capsule retirement](https://www.ingress.com/en/news/retiring-quantum-capsule).
This list adds parser coverage; the four existing image fixtures only verify
their own items. New item layouts still need captured OCR fixtures.

A shortened name counts only when what's shown starts exactly one item's name
and is at least half of it, such as `Kinetic C…` for Kinetic Capsule or
`Portal S…` for Portal Shield; `Portal…` stays unknown. Names cut at a
column's edge without a mark, and two-word names that lose their last word,
are recorded in Japanese panels; see [GAME_LANGUAGES.md](GAME_LANGUAGES.md).
A drop row names a transmuter by its short label with its sign, `ITO EN (-)`
(player report, 2026-10-01), which counts as ITO EN Transmuter (-). An
abbreviated name without the sign cannot distinguish the two variants, so it
stays unknown. Item names in other game languages are in `GameText.swift`.

## Rarity meters

Known items with rarity meters are read from pixels in the same source frame
as the OCR row. Portal Keys, Media and levelled items do not enter this path.
The name normally decides only whether to inspect a meter. Items that exist
in one rarity only take it from the recognized identity instead, still subject
to the two-read item confirmation gate, and the app applies it to readings
saved before the rule covered them. No meter read is claimed for this rule.

| Fixed rarity | Items | Source |
|---|---|---|
| Very Rare | Aegis Shield, Hypercube, ADA Refactor, JARVIS Virus | player's reports; [item reference](https://ingress.wiki.gg/wiki/Portal_Shield#Aegis_Shield) for Aegis |
| Very Rare | SoftBank Ultra Link, ITO EN Transmuter (+), ITO EN Transmuter (-) | [FevGames rarity guide](https://fevgames.net/ingress/ingress-guide/concepts/rarity/) |
| Rare | Turret, Force Amp | FevGames rarity guide; [Turret](https://ingress.fandom.com/wiki/Turret) and [Force Amp](https://ingress.fandom.com/wiki/Force_Amp) wiki pages; the recorded `five-base` Turret shows two purple bars |

Portal Shield, Heat Sink, Multi-Hack, Link Amp and Kinetic Capsule come in
more than one rarity, and Capsule's is not established, so their meters are
read. Portal Keys and Media have no meter.
The expected patterns are one green bar followed by two inactive bars (Common),
two purple bars followed by one inactive bar (Rare), or three pink bars (Very
Rare). These colors agree with the [Ingress mod rarity guide](https://www.penwatch.net/ingress_guide/mods/rarity/).
OCR slash counts are not rarity evidence. All three bar positions and the dark
gaps must be visible and agree; mixed colors, clipped or obscured meters remain
unreadable. The fixed meter geometry includes a small translation tolerance.

Rarity uses the existing two-read, 100 ms confirmation gate independently of
name/level detail. Missing detail cannot confirm a rarity or extend its voting
window. Once confirmed, a temporarily unreadable meter does not erase it;
contradicting confirmed rarities keep the entry uncertain. An unreadable rarity
is shown on the item as unread, like an unread level: it keeps the confirmed
quantity and does not mark the panel partial.
Different shield rarities at different row positions remain separate.

Each entry carries optional `rarity` (`common`, `rare`, `veryRare`, or
`unreadable`) through frame logs, summaries and saved history. Nil means the
field was not recorded or is not applicable; old records are not backfilled.
The app shows localized rarity badges beside the item details.

Validation: the recorded `five-base` Turret has two purple bars and reads as
Rare. Synthetic meters cover all three patterns at multiple resolutions,
occlusion, translation, wrong bar counts and contradictory colors. Recorded
Common and Very Rare meters still need regression fixtures; synthetic coverage
does not establish accuracy on those real captures.
An additional image test verifies that Aegis Shield, Hypercube, ADA Refactor,
JARVIS Virus and Force Amp keep their fixed rarity even with no meter pixels, and parser/tracker tests cover the Kinetic Capsule abbreviation
and the fixed-rarity confirmation and serialization path.

## ITO EN effects

An applied effect is separate from receiving a transmuter item. The player's
report gives `ITO EN (+) applied.`; the [documented full label](https://ingress.fandom.com/wiki/ITO_EN_Transmuter)
is `ITO EN Transmuter (+) applied.` (and the corresponding minus variant).
Both spellings map to `ITO EN (+)` or `ITO EN (-)`. Unicode minus, and the en
and em dashes OCR can read it as, are accepted; the sign must be present. Truncated item names never identify either variant.

Only a high-confidence known effect label immediately below the panel title
is excluded from item rows. Unknown text ending in “applied” stays unreadable;
raw text is never saved as effect metadata. Physical row positions stay stable
when a frame misses the label, with room for six item rows below an effect.
Effects need two agreeing reads spanning 100 ms, using the same gap and
conflict rules as items. Unconfirmed or conflicting effects keep the panel
partial. Portal and Bonus panels confirm effects independently.

Confirmed effects are saved in each panel's optional `effects` field, carried
through JSON logs and hack history, and displayed under the panel heading.
Old saved panels without the field decode normally. Effects do not contribute
to item quantities or imply that any other mod was applied.

## Multiplied quantities

The game prints a quantity in white, or in red when a multiplier applied to
the drop, such as on the first hack of the day. In the player's 2026-09-28
capture of a first hack of the day, every quantity in both the portal and
Bonus panels was red. Which multipliers exist, and whether the game ever
prints some quantities of a panel in red and others in white, is not known.

The colour is read from the pixels of the OCR box around the `x2` text alone,
never from the whole row: the level beside it has its own colour, and L4 and
L5 are red and pink. At least 85% of the text pixels must be red (within 20°
of pure red, saturated) or white (unsaturated); anything else, such as a box
that also takes in a level or a sparkle, stays unread. A row whose quantity
spans several OCR lines is not read.

The colour is voted apart from the item: two reads of the settled quantity
must agree, and none may contradict them. An unread or contradicted colour
leaves the item unmarked; it never makes the row or panel partial. Each entry
carries an optional `multiplied` value through frame logs, summaries and saved
history; nil means it was not read, and older records are not backfilled.

The app prints such a quantity in red and marks it "in red" on the hack card:
the game coloured the number, and an x1 was not multiplied by anything. The
Statistics details count those items, and the summary card adds that count
("26 in red") when there are any. The export keeps its `multiplied` column.

Validation: `multiplied-base` and `multiplied-bonus` are masked frames of the
2026-09-28 capture, and every entry in them reads as multiplied; every entry
in the four earlier fixtures reads as not multiplied, including the white
quantity beside an L5 level. The full capture replays with all six entries
multiplied in both live and exhaustive modes (`multiplied-annotation.json`).
Synthetic boxes cover faint red, level colours in the box and too little ink.
