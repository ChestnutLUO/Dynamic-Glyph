# Game languages

Ingress has its own language setting, independent of the iPhone's. The app
reads the game's text for phases, results, command notices and item panels,
so it needs the game's language, and Vision needs the right script before it
can read anything. Everything else it reads (levels such as `L8`, quantities
such as `x2`, rarity bars, red multiplied quantities, the panel and result
shapes) is the same in every language.

## Languages

| Language | Source of its text | Checked against a recording |
|---|---|---|
| English | the game | yes |
| 简体中文 | the player's sheet | yes, 2026-09-25 and 2026-09-29 |
| 日本語 | the player's sheet | yes, 2026-09-29 (three recordings) |
| 繁體中文 | the player's sheet | no |
| 한국어 | the player's sheet | no |

The text lives in `GameText.swift`, one pack per language, taken from
`GAME_TEXT_TRANSLATIONS_ALL.csv`. Chinese and Japanese games leave some text in
English (Power Cube, Portal Key, Heat Sink, Link Amp in Chinese; NO KEY, HACK
BONUS and SPEED BONUS in Japanese), so English is read in every pack as well.
Matching ignores case, spaces and punctuation and is otherwise exact.

Recordings confirmed, for Chinese: the notices except ONLY KEY and INVALID
COMMAND, the drone footer, both result labels, the Bonus title, Portal not in
range, and eleven item names. For Japanese: the notices except SIMPLE and
INVALID COMMAND, the drone footer, both result labels, the Bonus title, the
cooldown message and eight item names. The header lines were under the
floating window in every recording, and the Bounty Claimed, scanner and ITO EN
texts never appeared, so those come from the sheet alone.

## Finding the language

`GameLanguageMemory` holds the capture's language. Settings offer Automatic
(the default) or a fixed language.

- Automatic starts from the language last found, else the iPhone's language
  when it is one of these, else English.
- When a screen confirmed by its shape (a result page, an item panel, a notice
  box) yields no known text, or an item panel leaves any row unnamed, its
  reader tries the other languages on that same frame. The first whose own
  text matches (a result label, the Bonus title, a notice not left in English)
  becomes the language and is kept for the next capture. Each kind of screen waits one second between tries (a notice
  half a second), so an unreadable screen, such as one under the floating
  window, costs little.
- A fixed language never changes. Settings show what was found.
- A screen read in the current language's own words confirms it, so saved
  records can tell a detected language from the starting guess. English is
  confirmed only by its Bonus title: Japanese games print the result labels
  and NO KEY in English too.

For a portal panel, a reader may recover localized item names without a label
that identifies the game's language. Its rows can be returned if they improve
coverage and preserve every quantity and known identity from the original
read of that same frame. Shared English names alone cannot select this reader.
It is reused for successive samples of the same panel, with its evidence
checked again each time. This temporary choice expires after five seconds
without a successful read, a change in panel bounds, or a backwards timestamp;
it never updates Settings or the saved game language. Conflicting equally
complete alternatives leave the original read unchanged.

The first hack in a new language can lose its command notices: they are read
in the old language until another screen names the new one.

## Confidence

Vision reports Chinese, Japanese and Korean text at coarse levels, 0.3, 0.5 or
1, even when every character is right. English keeps its thresholds; the other
languages accept 0.5 for titles and notices (a notice read once at 0.5 stands
alone, except one the game leaves in English, such as NO KEY in Japanese, which
stands alone only at English's level and otherwise needs a second read) and
0.3 for item rows and result labels. Exact phrases, and two agreeing
reads for item rows, remain the guard against misreads. The header uses
Vision's accurate recognition in these languages, as the fast one reads Latin
script only.

## Shortened names

A panel shows a name shortened in three ways, all recorded:

- with "…" or "...", as English does ("Kinetic C…");
- cut at the column's edge with no mark, as Japanese does ("XMPバースタ" for
  XMPバースター, "パワーキュー" for パワーキューブ);
- with its last word dropped, as Japanese does for two-word names ("Aegis" for
  Aegis シールド, "ポータル" for ポータル シールド).

The first two count when what's shown starts exactly one item's name and is at
least half of it (three characters at least); the column case applies only
when the row's text reaches within 5% of its column's edge. The third counts
when the shown words open exactly one item's multi-word name, in languages
other than English, and only when the row stops short of its column's edge: at
the edge the cut may fall inside a word. A one-word name such as ポータルキー can't lose a word, so
ポータル is the shield. ITO EN Transmuter (+) and (-) never match a shortened
name: without the sign they can't be told apart.

## Adding a language

Add its column to the sheet, then a pack in `GameText.swift` and its Vision
language in `GameLanguage.recognitionLanguages`. Before calling it checked,
replay a recording with `Tools/check-command-replay.py --game-language <code>`
and add masked fixtures under `Fixtures/Assets/Screenshots/Languages` (the test-assets submodule).
