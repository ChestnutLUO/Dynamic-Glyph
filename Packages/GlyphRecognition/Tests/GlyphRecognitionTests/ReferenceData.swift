import Foundation
import Testing
@testable import GlyphRecognition

/// Loads the third-party reference tables used as a correctness oracle.
/// See `Fixtures/PROVENANCE.md` — these are inputs, not shipped data.
///
/// Copied into the test bundle rather than read from the source tree: Xcode
/// Cloud runs the tests on a different machine from the one that built them,
/// where the checkout — and so any `#filePath` — does not exist. The macOS 27
/// provenance attribute that codesign rejects on a fresh bundle is handled by
/// the Makefile's clear-and-retry, the same as for the test bundle itself.
///
/// The optional tables are copied only when present locally, so on a runner
/// without them the gated tests skip exactly as they do on a fresh clone.
///
/// The game screenshots are local inputs too: they are frames of the game's
/// own screen, so they live in a private test-assets repository, mounted as a
/// git submodule at `Fixtures/Assets` and bundled with the rest of `Fixtures`.
/// Its `Screenshots` folder holds them, one folder per fixture set, and is
/// `fixturesDirectory`.
/// Every test that reads `fixturesDirectory` decodes one of them, so when none
/// is present (the submodule is not checked out) the getter cancels the
/// running test with the reason, and it is reported as skipped, as a missing
/// table skips the tests above. With the screenshots in place nothing
/// changes: a single missing file still fails its test.
enum ReferenceData {
    static var fixturesDirectory: URL {
        get throws {
            try requireScreenshots()
            return bundledScreenshots
        }
    }

    private static var bundledScreenshots: URL {
        bundledFixtures.appendingPathComponent("Assets/Screenshots")
    }

    private static var bundledFixtures: URL {
        (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Fixtures")
    }

    /// True when any screenshot (`.png` or `.jpg`) is in the bundled screenshots.
    static let screenshotsAvailable: Bool = {
        guard let files = FileManager.default.enumerator(at: bundledScreenshots, includingPropertiesForKeys: nil)
        else { return false }
        return files.contains { item in
            guard let url = item as? URL else { return false }
            return ["png", "jpg"].contains(url.pathExtension.lowercased())
        }
    }()

    /// Skips the running test when the game screenshots are not in this
    /// checkout. For the few tests that find a screenshot without going
    /// through `fixturesDirectory`.
    static func requireScreenshots() throws {
        guard screenshotsAvailable else {
            try Test.cancel("Game screenshot fixtures are not in this checkout: they are not distributed with the source (private submodule Fixtures/Assets). See Fixtures/PROVENANCE.md.")
        }
    }

    /// Gate only tests that read the corresponding optional input. Independent
    /// parser, predictor, geometry and display tests must always run.
    static var shapesAvailable: Bool { exists("glyph_line.csv") }
    static var sequencesAvailable: Bool { exists("glyph.csv") }
    static var isAvailable: Bool { shapesAvailable && sequencesAvailable }

    private static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: bundledFixtures.appendingPathComponent(name).path)
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: bundledFixtures.appendingPathComponent(name), encoding: .utf8)
    }

    static func glyphTable() throws -> GlyphTable {
        try GlyphTable.parse(csv: text("glyph_line.csv"))
    }

    static func sequenceTable() throws -> SequenceTable {
        try SequenceTable.parse(csv: text("glyph.csv"))
    }
}

@Test("Full validation requires both local reference tables")
func requiredReferenceData() {
    if ProcessInfo.processInfo.environment["GLYPH_REQUIRE_REFERENCE_DATA"] == "1" {
        #expect(ReferenceData.shapesAvailable, "Missing glyph_line.csv; see Fixtures/PROVENANCE.md")
        #expect(ReferenceData.sequencesAvailable, "Missing glyph.csv; see Fixtures/PROVENANCE.md")
    }
}
