# DynamicGlyph

An iOS research prototype. In the mobile game Ingress, a "Glyph hack" shows a
short sequence of shapes that the player then has to redraw from memory. This
app watches the game on the player's own screen, recognises those shapes with
on-device image recognition, and shows the predicted sequence in a small
floating window and in the Dynamic Island.

The code is **source-available**: you can read it, under the terms in
[What you may do with this code](#what-you-may-do-with-this-code).

Device requirements, known limitations, and field-test evidence are documented
in the [field-testing instructions](Docs/FIELD_TESTING.md).

## Before you install this

Read this part. It is about your account, not ours.

The app watches the screen while you play and tells you what it saw. Ingress is
now operated by Niantic Spatial. Its
[Player Guidelines](https://www.nianticspatial.com/en/guidelines) list "using
modified or unofficial software" as a form of cheating, and this app is
unofficial software. It does not modify or talk to the game, but the guidelines
draw no line between software that changes the game and software that helps you
play it.

Niantic Spatial finds violations through automated systems and player
reports. A violation can lead to a warning, degraded gameplay, suspension, or
permanent termination, "sometimes without warning". The action can reach every
Niantic Spatial product, and you may be barred from creating a new account.
That falls on the player's account, not on this repository. Read the guidelines
and the [Terms of Service](https://nianticspatial.com/terms) yourself before you
install.

Nothing here is hidden from you: it captures the screen with the system
recording indicator visible throughout, and it keeps its evidence in files you
can read. Install it understanding what you are choosing.

## What you may do with this code

The code is published under the [PolyForm Strict License 1.0.0](LICENSE). In
plain words:

- You **may** read it, and build it and use it yourself for non-commercial
  purposes.
- You **may not** change it, redistribute it or publish it, in any form,
  including on the App Store.
- For anything else, ask: <dynamic-glyph@szres.org>.

The LICENSE file is the binding text; this list only summarises it.

The name "Dynamic Glyph" and its icons are not licensed, and game imagery and
trademarks belong to their owners. See [NOTICE](NOTICE.md). Suggestions and
pull requests are welcome on the terms in [CONTRIBUTING](CONTRIBUTING.md).

Two kinds of test input are not distributed: the game screenshots that the
recognition tests read, and the third-party reference tables. Tests that need
them are reported as skipped. See their
[provenance](Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/PROVENANCE.md).

## Building it yourself

You need a Mac with **Xcode 27** (tested with Xcode 27.2) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (tested with 2.46.0). The
app runs on iOS 18 or later and captures through ScreenCaptureKit on iOS 27.
It cannot run in the Simulator, so to use it you need an iPhone and an Apple
Developer account.

```sh
brew install xcodegen
cd Apps/DynamicGlyph && xcodegen generate
open DynamicGlyph.xcworkspace
```

That is enough to run the tests in the Simulator (see [Tests](#tests)). To
install on your own iPhone:

1. **Team ID.** Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`
   and set `DEVELOPMENT_TEAM` to your team identifier, which is listed under
   Membership in the Apple Developer portal. That file is gitignored.
2. **Bundle identifier.** `org.szres.DynamicGlyph` is registered to this
   project, so you need your own. Replace `org.szres` with a prefix you own
   everywhere it occurs in `Apps/DynamicGlyph/project.yml`: `bundleIdPrefix`,
   the `PRODUCT_BUNDLE_IDENTIFIER` of the app and the two extensions
   (`.GlyphWidget`, `.GlyphBroadcast`) and the test target. Then change
   `BroadcastChannel.extensionBundleID` in
   `Apps/DynamicGlyph/FrameTransport/BroadcastChannel.swift`.
3. **App Group.** The app shares `group.org.szres.DynamicGlyph` with both
   extensions. Pick your own, for example `group.<your prefix>.DynamicGlyph`,
   and set it in the three `com.apple.security.application-groups` entries in
   `project.yml`, in `BroadcastChannel.appGroup`, and in the `appGroup`
   constant in `Apps/DynamicGlyph/Shared/StatisticsWidgetSummary.swift`.
4. **iCloud container.** Result sync uses the CloudKit container
   `iCloud.org.szres.DynamicGlyph`. Set your own in `project.yml`
   (`com.apple.developer.icloud-container-identifiers`) and in
   `HackResultStore.cloudContainer` in
   `Apps/DynamicGlyph/Sources/Results/HackResultStore.swift`.
5. Run `xcodegen generate` again, choose your iPhone and build the
   `DynamicGlyph` scheme. With automatic signing, Xcode registers the App IDs,
   the App Group and the iCloud container from the Signing & Capabilities tab.

Steps 2 to 4 edit the source, which the PolyForm Strict License does not
allow by itself. As the licensor, ChestnutLUO also permits these edits, and only
these: changing the team, bundle identifiers, App Group and iCloud container so
that you can build and use the app on your own devices under the terms above. The
[contributor guide](CONTRIBUTING.md#signing) covers signing and CloudKit in
more detail.

## Layout

| Path | What it is |
|---|---|
| `Packages/GlyphRecognition` | Pure Swift pixel recognition, Glyph/sequence tables and prediction. Separate Apple image-decoding adapter and a `glyph-recognize` CLI. See [recognition usage](Packages/GlyphRecognition/RECOGNITION.md). |
| `Apps/DynamicGlyph` | The app: capture, recognition, phase and slot tracking, prediction, a Picture in Picture sequence viewer and a Live Activity. See [field testing](Docs/FIELD_TESTING.md); the original capture verdict is in [capture results](Docs/CAPTURE_SPIKE_RESULT.md). |
| `Tools/detect-nodes.swift` | Finds the eleven array nodes in a captured frame. How `NodeArray.canonical` was derived. |
| `Tools/check-phase-replay.py` | Replays a recording through the whole live pipeline and checks the recovered sequence against the manual annotation. |
| `Tools/check-ablations.py` | Replays every annotated recording with one pipeline component switched off at a time. See the [ablation study](Tools/AblationResults/2026-09-22/README.md). |

Xcode projects are generated from `project.yml` and are not committed (see
[Building it yourself](#building-it-yourself)). Open the committed workspace, which includes the package as a top-level item.
The `DynamicGlyph` scheme builds the app for a phone, and ⌘U with an **iOS 27
simulator** selected runs both the app's tests (`DynamicGlyphTests`) and the
package's. The app itself cannot be built for a simulator — ScreenCaptureKit is
not in the simulator SDK — so the test target compiles only the app sources it
tests. Regenerating the project preserves all of this.

## Tests

```sh
cd Packages/GlyphRecognition && make test           # package only, on the Mac
xcodebuild test -workspace Apps/DynamicGlyph/DynamicGlyph.xcworkspace \
  -scheme DynamicGlyph -destination 'platform=iOS Simulator,name=<an iOS 27 iPhone>'
```

`make` rather than `swift test` directly: macOS 27 stamps `com.apple.provenance`
on files written by unsigned processes and the codesign step rejects bundles
carrying it, so the build has to be run, the attribute cleared, and the signing
retried. The Makefile does that.

Reference tables are optional local inputs. Tests that require missing tables
are reported as skipped; independent tests still run. For full corpus validation,
run `make test-full` from the package directory (missing tables fail this mode),
or set `GLYPH_REQUIRE_REFERENCE_DATA=1` when running Swift/Xcode tests. See
[reference data](Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/PROVENANCE.md).
A green run with skips is not evidence that the full corpus passed.

The game screenshots and crops the recognition tests read are not distributed
either. They are in a private git submodule at
`Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/Assets`;
with access, `git clone --recurse-submodules` fetches them and those tests run.
Without them, the tests that read them are reported as skipped with the reason.

Repository maintenance scripts have an offline regression harness:

```sh
python3 scripts/tests/test_repository_scripts.py
```

It uses disposable repositories and never touches this checkout. The download
success test needs the optional CSVs; the rejection test always runs.

## State

- ScreenCaptureKit capture of a foreground third-party app is **proven** on
  iOS 27.2, un-redacted, while backgrounded.
- Node geometry and labelling are **derived and tested**, with one documented
  limit: a whole-array left-right reflection cannot be ruled out from the data
  alone and needs an independently labelled capture.
- Pixel recognition is **implemented**: node-ring fitting, line evidence,
  direction-independent shape matching, and spatial accumulation within one
  Glyph. Positive recognition is validated on synthetic images of all 142
  shapes and one manually annotated five-Glyph recording. See the
  [recording validation](Tools/RecordingResults/2026-09-17/README.md).
- Game phase and presentation slots are **implemented and validated offline**.
  The phase comes from the header text, the slot count and the current slot
  from the indicator strip, and a Glyph is only confirmed in the sequence when the
  indicator advances or the presentation ends. Replaying the recording through
  the whole pipeline recovers `see, truth, see, future, begin` with no
  annotation in the loop — see the
  [phase replay](Tools/PhaseReplayResults/2026-09-18/README.md).
- Sequence prediction is **connected**, and now takes the independently counted
  slot count into account. Without it the recording's four-Glyph prefix stays
  ambiguous, because it is itself a complete sequence in the table.
- The Picture in Picture sequence viewer and the Live Activity are
  **implemented**. Current device evidence and remaining checks are documented
  in the [field-testing instructions](Docs/FIELD_TESTING.md).
- iOS 18–26 capture runs through a ReplayKit broadcast extension, whose
  frames reach recognition in the app through a shared-memory ring
  ([protocol](Docs/FRAME_TRANSPORT.md)). There the floating window is
  required, because the app keeps running over Ingress only while it is open.
  First device run on iOS 26: one complete hack recognised, results read,
  20 Hz with no frames lost, extension peak 9.7 MB. Longer sessions are still
  to be measured.
