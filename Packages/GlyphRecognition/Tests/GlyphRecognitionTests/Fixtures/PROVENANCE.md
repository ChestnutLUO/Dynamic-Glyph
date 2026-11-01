# Reference data — third party, not included

`glyph_line.csv` (shapes) and `glyph.csv` (sequences) are **not in this
repository**. They were copied verbatim from
<https://github.com/chibatching/glyph-predictor-data>, which **publishes no
licence**, so they are not ours to redistribute. Nothing here may be assumed to
grant you rights over them.

They are a correctness oracle for the tests, never shipped in a binary. The app
reads its own copies from its Documents folder at run time and degrades honestly
without them: no shape table means capture will not start, and no sequence table
means the display says `Prediction unavailable`.

## Running the tests without them

Only tests that read a missing table are skipped. Parser, predictor, geometry,
indicator, OCR and display checks with independent inputs still run. Inspect the
skip count: a green default run is not a full reference-corpus validation.

For full validation after installing both inputs:

```sh
make -C Packages/GlyphRecognition test-full
# Alternative with the native build system:
cd Packages/GlyphRecognition
GLYPH_REQUIRE_REFERENCE_DATA=1 swift test --build-system native
```

Both forms fail if either table is absent. Xcode can use the same environment
variable in the `GlyphRecognitionTests` scheme's test action.

## Getting them

```sh
scripts/fetch-reference-data.sh
```

The script fetches the pinned upstream revision into a temporary directory and
verifies both SHA-256 hashes before copying either file here. It is never run by CI. Read it before you run it, and
satisfy yourself about the upstream licence position for your own use.

Validated revision: `109f6c32d24c9f219e946a1423642390db6ce86b`.
The hashes cover raw bytes, including LF in `glyph_line.csv` and CRLF in `glyph.csv`.

| File | SHA-256 |
| --- | --- |
| `glyph_line.csv` | `72c3e0f1b93992cf725bf2ce8adfdb2df4daddf6b5f8a6c8f7e8629e6934b6e7` |
| `glyph.csv` | `b1eaac450aa60643e25c17ae5c12ba8803dd0c50d60823dda5f6768ba9e2c5bf` |

Format:

- `glyph_line.csv` — `name,shape`, where shape is a walk over nodes `0`-`9`, `a`.
- `glyph.csv` — one sequence per row, Glyph names in order, padded to five columns.

## Game screenshots

The `.png` and `.jpg` files the tests read are frames and crops of the game's
own screen, masked for privacy before they were committed. The game's imagery
belongs to its owners, so they are not distributed with the source. They live
in a private repository, szres/dynamic-glyph-assets, mounted here as a git
submodule at `Assets/`. Its `Screenshots/` folder has one folder per fixture
set (`Assets/Screenshots/Gear/`, `Assets/Screenshots/Phases/`, …), each with a
README describing its frames and masking. The annotation JSONs stay in the
matching folders here. With access, `git clone --recurse-submodules` (or
`git submodule update --init`) fetches them; without it `Assets/` stays
empty.

Without them, every test that reads a screenshot is reported as **skipped**
with the reason, through `ReferenceData.fixturesDirectory` in the package and
`TestFixtures` in the app's tests. Everything else still runs. As with the
tables, a green run with skips is not evidence that the recognition corpus
passed. With the screenshots in place nothing is skipped, and a single
missing file fails its test.

## App imports and a possible bundled replacement

TestFlight testers can import both CSVs using the app's **Import shapes** and
**Import sequences** buttons and the Files picker; direct container access is
not required. Files can first be transferred to the phone through Files or
AirDrop. The app copies the selected inputs into its Documents directory.

An independently collected or licensed table could simplify onboarding by
allowing a bundled default. That is a separate data project, not a prerequisite
for the existing import flow. `Tools/detect-nodes.swift` and the recognizer can
assist capture annotation, but capture-derived data still needs validation.
