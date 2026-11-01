// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlyphRecognition",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GlyphRecognition", targets: ["GlyphRecognition"]),
        .library(name: "GlyphRecognitionImages", targets: ["GlyphRecognitionImages"]),
        .executable(name: "glyph-recognize", targets: ["GlyphRecognize"]),
        .executable(name: "glyph-replay", targets: ["GlyphReplay"])
    ],
    targets: [
        .target(
            name: "GlyphRecognition",
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(name: "GlyphRecognitionImages", dependencies: ["GlyphRecognition"],
                resources: [.process("Localizable.xcstrings")]),
        .executableTarget(name: "GlyphRecognize", dependencies: ["GlyphRecognition", "GlyphRecognitionImages"]),
        // Replays captured frames through the whole live pipeline, including
        // the slot-indicator reader and header text recognition, so the
        // boundaries under test are derived from pixels rather than annotated.
        .executableTarget(name: "GlyphReplay", dependencies: ["GlyphRecognition", "GlyphRecognitionImages"]),
        .testTarget(
            name: "GlyphRecognitionTests",
            // GlyphReplay is here for its ablation switches, which exist only
            // in the replay and are tested like any other pipeline rule.
            dependencies: ["GlyphRecognition", "GlyphRecognitionImages", "GlyphReplay"],
            // Bundled so the tests find them on a runner with no checkout --
            // see ReferenceData.swift.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
