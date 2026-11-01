# Gear export format, version 1

The Statistics page exports gear as one CSV file, for the player's own
analysis or to share. This is its specification. The code is
`Apps/DynamicGlyph/Sources/Results/GearExport.swift`, and its tests are
`GearExportTests`.

## What the file is, and isn't

- **Only what the app read.** A hack the app didn't follow, a group of panels
  shown while capture was off, and a group in which no row was read are not in
  the file. A day's rows are not all the hacks played that day.
- **A drop is a group of panels, not a confirmed hack.** `association` says how
  a group was matched to a hack; `ordered` is first-in-first-out order, not
  proof.
- **Blank means unknown, never zero or false.** A known `false` or `0` is
  written out.
- No exact times, portal names, notes, pictures, raw text, device details,
  storage keys or file paths are written. The player's faction is, when set:
  with `portal_alignment` it can be told from the portal's anyway.

## The file

- UTF-8, no byte-order mark. RFC 4180: comma-separated, a field with a comma,
  quote or line break is quoted with its quotes doubled, and lines end in
  CRLF.
- One header row with every column below, in this order, in every file.
  No comment lines.
- Named `DynamicGlyph-gear-v1-<export date>.csv`.
- **One row per item read**, with its record's and panel's columns repeated.
  A record or panel with nothing to list still gets one row, with the item
  columns blank (see [Rows](#rows)).
- Records are ordered by time.

Count records with distinct `record_id`, never rows.

## Columns

| Column | Type | Values and meaning |
| --- | --- | --- |
| `format_version` | integer | `1`. A column is only added at the end within a version; renaming or removing one makes version 2. |
| `record_id` | id | See [Record ids](#record-ids). |
| `kind` | enum | `hack`: a Glyph hack and the gear read for it. `drop`: a group of panels no Glyph hack claimed. |
| `time_basis` | enum | What the time columns describe: `hack_first_seen`, when the app first saw the hack (its input screen); `drop_closed`, when the app closed the group of panels. Both are times the app received something, not times the game reported. |
| `time_bucket_start_utc`, `time_bucket_end_utc` | timestamp | The interval holding that time, `YYYY-MM-DDTHH:MM:SSZ`, start included and end excluded. An hour, or a day with **Include the hour** off. See [Time](#time). |
| `local_date` | date | `YYYY-MM-DD` in the capturing iPhone's offset. Blank when the offset isn't known. |
| `local_hour` | integer | 0–23 in that offset. Blank when the offset isn't known or the hour is off. |
| `utc_offset_minutes` | integer | The capturing iPhone's offset from UTC at the record's time (for a hack, when it was first seen, even if a time change came before it closed), such as `480` or `-210`. Blank for records from before it was kept. |
| `session` | integer | The capture session, numbered 1, 2, … in this file by its first record. **Not stable across files.** |
| `order` | integer | The record's place among this file's records of that session, from 1. Gaps in capture don't show. |
| `read_status` | enum | `read`: the gear reading is in the row. `notRead`: the hack stopped waiting with no panels (`read_reason` says why). `unavailable`: no gear reading for this hack, as when gear reading was off. `unsupported`: gear was saved in a format this build can't read. Drops are always `read`. |
| `read_reason` | id | For `notRead`: `waitTimeout` (no panels within the wait), `frameGap` (capture lost frames), `queueLimit` (too many hacks waiting) or `captureStopped`. Otherwise blank. |
| `association` | enum | `ordered`, `orderedWithoutBonus`, `bonusExpected`, `noWaitingHack`, `uncertainContinuity` or `unassociated`. See `GearDropSummary.Association` and [gear-drop recognition](https://github.com/szres/dynamic-glyph-assets/blob/main/Docs/GEAR_DROP_RECOGNITION.md) (in the private test-assets repository). |
| `observed_panels_read_in_full` | boolean | Every panel seen was read with no unidentified row. Panels never seen can't count against it. |
| `both_panels_read` | boolean | The portal panel then a Bonus panel, both read in full. Drops often have no Bonus panel. |
| `panel` | enum | `portal` or `bonus`. |
| `panel_partial` | boolean | The panel was only partly read. |
| `panel_effects` | list | Effects the panel showed, such as `ITO EN (+)`. Blank when none were shown or for readings from before effects were read. |
| `slot` | integer | The item's place on its panel, from 0: row × 2 + column. Not combined with equal items elsewhere. |
| `item` | text | The item's English name as the game prints it, from a fixed list. Blank when the row was read but its name wasn't recognized. |
| `level` | integer | 1–8, for items with a level. |
| `level_state` | enum | `known`, `notApplicable` (the item has no level) or `unreadable`. |
| `rarity` | enum | `common`, `rare`, `veryRare` or `unreadable`. Blank for items without a rarity meter or older readings. |
| `rarity_source` | enum | `fixed`: the item comes in one rarity, from the app's catalogue (which may grow in later versions). `read`: read from the panel's pixels. |
| `quantity` | integer | As the game printed it. Blank only on rows with no item. |
| `multiplied` | boolean | The game printed the quantity in red, as on the first hack of the day. Blank when the colour was unclear or not read. The multiplier itself isn't known. |
| `hack_state` | enum | The hack's result screen: `complete`, `partial`, `notObserved`, or `awaiting` if it closed before any was read. |
| `hack_glyph_count` | integer | Glyphs in the hack. |
| `hacking_bonus`, `speed_bonus` | integer | Percent. |
| `hacking_bonus_final`, `speed_bonus_final` | boolean | `false` for the last value seen before the game settled it. |
| `command_mode` | enum | `portal`, `drone` or `unknown`. |
| `speed_command`, `key_command` | enum | The command in effect: `simple`, `complex`, `requestKey`, `noKey` or `keysOnly`. Blank unless confirmed. |
| `speed_command_status`, `key_command_status` | enum | `confirmed`, `unresolved`, `noCommandObserved` or `notApplicable`. |
| `portal_level_low`, `portal_level_high` | integer | The portal level's range; equal when one level. Hacks only. |
| `portal_level_confidence` | enum | `low`, `medium` or `high`. |
| `portal_level_conflict` | boolean | The sources disagreed; the range follows the strongest. |
| `capture_mode` | enum | `glyphAssistance` or `gearOnly`. |
| `game_language` | enum | `en`, `zh-Hans`, `zh-Hant`, `ja` or `ko`: the language the app read the game in. |
| `game_language_source` | enum | `chosen` by the player; `detected`, seen in its own words on a screen of that capture; or `assumed`, automatic reading's starting guess (the last capture's language, the iPhone's, or English) before any screen confirmed it. For a hack, the latest summary's: the result screen often confirms it. |
| `source_app_version`, `source_app_build` | text | The app that captured the record. |
| `exporter_app_version`, `exporter_app_build` | text | The app that wrote this file. |
| `portal_faction` | enum | `resistance`, `enlightened` or `machina`: the colour of the resonator bars on a recently read portal screen associated with a Glyph hack. This is a temporal association, not a verified portal identity; see the limits below. Blank without an associated screen, including ordinary hacks and gear-only capture. Neutral screens have no bars and cannot be detected yet. |
| `player_faction` | enum | `resistance` or `enlightened`, as set in Settings › Your faction when the record was captured. Blank when it wasn't set. |
| `portal_alignment` | enum | `same_faction`, `enemy` or `machina`: the portal's faction against the player's. `machina` needs only the portal's; the others need both, so blank otherwise. A `neutral` value is reserved for when neutral portals are recognized. |

The hack columns are blank on drop rows; the panel and item columns are blank
when there's no reading.

### Portal association limits

A portal read is attached to the next Glyph hack within 10 seconds. A change
in the detected faction or a read more than 1.5 seconds after the retained
screen replaces its labels and badge, even if no new label was readable.
Late OCR taken before a hack started cannot be reused for the next hack.

The app does not retain portal identity. If an intervening portal screen is
missed entirely (including an undetectable neutral screen), an earlier screen
can still fall inside that window. `portal_faction` and `portal_alignment`
therefore describe the associated observation, not proof of the hacked
portal's identity. Portal-level confidence does not measure this association.

### Only in new records

`utc_offset_minutes`, `local_date`, `local_hour`, `capture_mode`,
`game_language`, `game_language_source`, `source_app_version`,
`source_app_build` and `player_faction` come from what the capturing iPhone
saved with the record. `portal_faction` comes from builds that read it
(beta 0.1.0-4 on). `portal_alignment` needs a saved player faction too, except
for `machina`.
Records from builds before that are blank in these columns. They are never
filled in from the exporting iPhone, which may be another iPhone or build.

## Rows

| Record | Rows |
| --- | --- |
| A reading with items | One per item. |
| A panel seen with no row read | One, `panel` set, item columns blank. |
| A reading with no panel | One, `panel` and item columns blank. |
| A hack with `notRead`, `unavailable` or `unsupported` gear | One, panel and item columns blank. |

Not in the file, and counted on the export sheet instead: a hack still being
read, and a record saved in a format this build can't read.

## Record ids

`h` for a hack or `d` for a drop, then the first 128 bits of the SHA-256 of
the record's saved key, in lowercase hex: 33 characters.

- The key holds a random number the app made when it launched, the capture
  session and the hack or group. It is never written to the file.
- The same record has the same id in every export, and from every iPhone it
  synced to through iCloud, so a collection can count it once.
- A record exported again may carry more: gear that arrived later. Keep the
  newest copy of an id.
- The letter keeps spreadsheets from reading an id like `12e45…` as a number.

## Time

The time columns describe `time_basis`, the time the app received the hack or
group. That is seconds after the game showed it, longer for a group that
waited in the queue, and can fall in the next hour or day.

- With the capturing iPhone's offset known, the interval is that offset's hour
  or day: at UTC+5:45 an hour runs from a quarter past in UTC. Each record
  uses its own offset, so a daylight-saving change or travel mid-session shows
  as two offsets.
- Without it, the interval is the UTC hour or day, and the local columns are
  blank.
- The export sheet's **Include the hour** switch is on by default. Off, the
  interval is the day and `local_hour` is blank.
- The text summary shared from the same sheet gives each record the same
  interval, such as `2026-10-03 07:00–08:00 UTC+08:00` or `2026-10-03
  UTC+08:00`, never its minute.

## Spreadsheet safety

Each column is written as its type allows: integers (possibly negative),
`true`/`false`, fixed words, ids, dates and timestamps. A `text` or `id` cell
that starts with `=`, `+`, `-`, `@`, a tab or a carriage return is written
with a `'` in front, so a spreadsheet doesn't run it as a formula. Version 1's
text comes from fixed lists and never starts that way. To read the original,
remove one leading `'` from a `text` or `id` cell. A negative number such as
`-210` is an integer and is never changed.

Lists hold their elements joined by `;`. Elements never contain `;`, and empty
elements are kept, so `a;;` splits into three.

## Reading it

```python
import pandas as pd

df = pd.read_csv("DynamicGlyph-gear-v1-2026-10-02.csv",
                 dtype=str, keep_default_na=False)  # keep ids and blanks as written
for column in ["quantity", "level", "slot", "local_hour", "utc_offset_minutes"]:
    df[column] = pd.to_numeric(df[column].mask(df[column] == ""))  # blank → NaN, not 0

records = df.drop_duplicates("record_id")
print(records.kind.value_counts())                    # hacks and drops
print(records.read_status.value_counts())             # what was read

items = df[df.item != ""]
print(items.groupby(["item", "level"], dropna=False).quantity.sum())
print(items.groupby("multiplied").quantity.sum())     # "" is unknown, not false
```

Merging files: keep one copy of each `record_id`, the one from the newest
export. `session` numbers mean nothing across files.
