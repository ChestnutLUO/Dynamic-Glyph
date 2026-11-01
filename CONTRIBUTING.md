# Contributing

Suggestions and pull requests are welcome. By submitting one, you grant
ChestnutLUO a perpetual, irrevocable, worldwide, royalty-free licence to use,
modify and distribute your contribution under any terms, including in the App
Store app. Please do not submit anything you cannot grant that licence for.

The code itself is available under the
[PolyForm Noncommercial License](LICENSE). You may change it and share your
version for non-commercial purposes, under its own name and icon (see
[NOTICE](NOTICE.md)). Fixes that help everyone are most useful sent here as a
pull request.

## Getting a project to open

There is no `.xcodeproj` in the repository. It is generated from
`Apps/DynamicGlyph/project.yml` and is gitignored, so a fresh clone opens to
nothing until you generate it:

```sh
brew install xcodegen
cd Apps/DynamicGlyph && xcodegen generate
open DynamicGlyph.xcworkspace
```

Open the **workspace**, not the project. It lists `Packages/GlyphRecognition`
as a top-level item, which is what makes the package's tests appear in Xcode's
test navigator; opening the project alone hides them.

`project.yml` is the source of truth for everything the project file holds —
targets, bundle identifiers, build settings and `Info.plist` contents. Changing
a setting in Xcode's inspector edits a generated file and the change is lost on
the next `xcodegen generate`. Edit the manifest instead.

## Where the app's code lives

`Apps/DynamicGlyph/Sources` is grouped by feature; Xcode shows the same groups.

| Folder | What is in it |
|---|---|
| `App` | The `@main` entry point, saved preferences, opening Ingress |
| `Capture` | Screen capture and the per-frame pipeline into the recognition package |
| `FloatingWindow` | Picture in Picture: controller, render loop, frame factory, inline layer host |
| `LiveActivity` | Starting and pacing the Dynamic Island / Lock Screen activity |
| `Recording` | Bug-report and Photos screen recordings |
| `Diagnostics` | Session logs, screenshots, counters, session reports and the Diagnostics page |
| `Home` | The home screen and its cards |
| `Setup` | First-run setup, its step order, Dynamic Island detection and the canvas preview |
| `Settings` | The Settings sheet and the canvas controls |
| `Intents` | The Shortcuts and Siri actions, and the requests they leave for the screens |
| `Components` | Views shared between screens |
| `Resources` | `Info.plist`, string catalogs and the privacy manifest |

`Shared` holds what the widget extension also compiles, and `Widget` the
extension itself. One view or type per file, named after it; a file keeps
small private helpers that nothing else uses.

## Signing

`Config/Build.xcconfig` is committed and optionally includes
`Config/Local.xcconfig`, which is not. To build on a device, create it:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# then set DEVELOPMENT_TEAM to your own team identifier
```

Without it the project still generates and builds for the simulator.

The app's entitlements include the iCloud container `iCloud.org.szres.DynamicGlyph`
(CloudKit) and push notifications, for the optional result sync. Your team's
App ID needs both capabilities and that container; automatic signing can
register them from Xcode's Signing & Capabilities tab. A build under your own
bundle identifier needs its own container, set in `project.yml` and in
`HackResultStore.cloudContainer`; the README's
[Building it yourself](README.md#building-it-yourself) lists every identifier
to change.

SwiftData creates the CloudKit record types in the container's Development
environment the first time a development build syncs. Deploy that schema to
Production in the CloudKit Console before a TestFlight or App Store build
syncs, and again whenever the saved schema changes.

## Versions

The marketing version is `DG_MARKETING_VERSION` in `Apps/DynamicGlyph/project.yml`;
bump it there, in a commit. The build number is `DG_BUILD_NUMBER`: `0` locally,
and Xcode Cloud's run number in CI, written by `ci_scripts/ci_post_clone.sh`.
Both apply to the app and the widget extension together, because App Store
Connect rejects an upload where the two disagree.

Builds ship only from tags: `beta/<version>-<n>` goes to external TestFlight
testers, and `release/<version>-<n>` is held in App Store Connect for review.

## Languages

The app ships in English, Japanese, Simplified Chinese and Traditional Chinese.
Every user-facing string is in a string catalog; [Docs/TRANSLATION.md](Docs/TRANSLATION.md)
covers how to add one, the glossary to keep terms consistent, and the review
state of the current translations.

## Tests

In Xcode, select an **iOS 27 simulator** and press ⌘U on the `DynamicGlyph`
scheme. That runs the app's tests and the package's together.

`DynamicGlyphTests` compiles the app sources it tests directly, because the app
imports ScreenCaptureKit and so cannot be built for a simulator. To test another
app file, add it to that target's `sources` in `project.yml`. It must not import
ScreenCaptureKit, ActivityKit or anything else missing from the simulator SDK.
Fixtures go in `Tests/DynamicGlyphTests/Fixtures` and are read from the bundle
with `TestFixtures.url(_:_:)`.

The recognition core is a plain SwiftPM package with no dependencies:

```sh
cd Packages/GlyphRecognition && make test
```

`make` rather than `swift test` directly: macOS 27 stamps
`com.apple.provenance` on files written by unsigned processes and the codesign
step rejects bundles carrying it, so the build has to be run, the attribute
cleared, and the signing retried. The `Makefile` does that.

The reference tables are not distributed (see the fixtures'
[`PROVENANCE.md`](Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/PROVENANCE.md)).
Tests needing them report as **skipped**, and everything else still runs — so a
green run with skips is not evidence that the full corpus passed. With your own
copy in place, `make test-full` requires them and fails if they are missing.

The game screenshots and crops are not distributed either: they are in a
private submodule at `Fixtures/Assets`. Tests that read them are reported
as skipped with the reason when none are present; with the submodule checked
out (`git submodule update --init`) they run.

The app ships for iOS 27, but it must also build for iOS 18, where capture
will come from ReplayKit instead. Put any API newer than iOS 18 behind
`#available` or `@available`, and keep ScreenCaptureKit inside the backend
(`ScreenCaptureBackend` and the outputs it registers): the engine,
recognition and the screens reach capture only through `CaptureBackend`.
This builds for iOS 18 without changing the shipping target:

```sh
sh scripts/check-ios18-build.sh
```

The repository maintenance scripts have their own offline harness, which works
in disposable repositories and never rewrites your checkout:

```sh
python3 scripts/tests/test_repository_scripts.py
```

## What a change is expected to carry

Recognition and display logic changes belong in `Packages/GlyphRecognition`,
which imports nothing — not even Foundation — and is where the tests live. If
you are changing what a surface claims to have observed, the test that pins the
claim is part of the change, not a follow-up.

The pixel-level pipeline has an end-to-end check that replays a recording
through the whole live path with no annotation in the loop:

```sh
python3 Tools/check-phase-replay.py <recording>.MP4 --output <results dir>
```

It needs a recording, which is not in the repository. If you have one, run it
for anything that touches the reader, the tracker or prediction.

## Before you open a pull request

- `cd Packages/GlyphRecognition && make test`
- ⌘U on the `DynamicGlyph` scheme with an iOS 27 simulator
- `cd Apps/DynamicGlyph && xcodegen generate` then build for an iPhone
- `sh scripts/check-ios18-build.sh`
- No absolute paths, team identifiers, device evidence, third-party tables or
  game screenshots in the diff. Describe a recognition failure in words, or
  with a synthetic image, rather than attaching a capture of the game.
