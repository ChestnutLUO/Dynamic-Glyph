import Foundation
import Testing

/// Fixtures are copied into the test bundle, so the tests read them the same way
/// on a simulator, a device or an Xcode Cloud runner — never through a path
/// baked in at compile time.
///
/// The game screenshots among them (`.png`, `.jpg`) are frames of the game's
/// own screen. They come from the `Screenshots` folder of the private
/// test-assets submodule at
/// `Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/Assets`
/// (see project.yml), so a checkout without it has none. When none
/// is in the bundle, asking for one cancels the running test with the reason,
/// and it is reported as skipped. With the screenshots in place nothing
/// changes: a single missing file still fails its test.
enum TestFixtures {
    private final class BundleToken {}

    static func url(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: ext) else {
            if ["png", "jpg"].contains(ext.lowercased()) { try requireScreenshots() }
            throw FixtureMissing(name: "\(name).\(ext)")
        }
        return url
    }

    /// True when any screenshot is in the test bundle.
    static let screenshotsAvailable: Bool = ["png", "jpg"].contains { ext in
        !(Bundle(for: BundleToken.self).urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []).isEmpty
    }

    /// Skips the running test when the game screenshots are not in this
    /// checkout. For the few tests that find a screenshot without `url(_:_:)`.
    static func requireScreenshots() throws {
        guard screenshotsAvailable else {
            try Test.cancel("Game screenshot fixtures are not in this checkout: they are not distributed with the source. See Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/PROVENANCE.md.")
        }
    }

    struct FixtureMissing: Error, CustomStringConvertible {
        let name: String
        var description: String { "\(name) is not in the test bundle" }
    }
}

/// A scratch directory removed when the value is released.
final class TemporaryDirectory {
    let url: URL

    init(_ label: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamicglyph-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
