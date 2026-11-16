// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The C++ core as a compiled binary or as sources. A checkout that ran
// scripts/build-glyph-core-xcframework.sh links the compiled framework into the
// app and the tests; a fresh clone or CI, which has no Binaries/ (it is
// ignored), builds the same sources. Both present the module GlyphCoreCxx from
// include/module.modulemap, so the bridge imports it the same way either way.
let glyphCoreBinaryPath = "Binaries/GlyphCore.xcframework"
let glyphCoreTarget: Target = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/" + glyphCoreBinaryPath)
    ? .binaryTarget(name: "GlyphCoreCxx", path: glyphCoreBinaryPath)
    // The pixel core in C++17 behind a C ABI (include/glyph_core.h). No
    // Apple framework, no allocation the caller does not own.
    : .target(name: "GlyphCoreCxx", path: "Sources/GlyphCoreCxx", publicHeadersPath: "include")

let package = Package(
    name: "GlyphRecognition",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GlyphRecognition", targets: ["GlyphRecognition"]),
        .library(name: "GlyphRecognitionImages", targets: ["GlyphRecognitionImages"]),
        // The C++ pixel core and its Swift bridge: the second recognition
        // engine. The app links it beside the Swift engine and chooses at
        // session start.
        .library(name: "GlyphRecognitionCxx", targets: ["GlyphRecognitionCxx"]),
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
        glyphCoreTarget,
        // Swift types in, C structs across the ABI, Swift types out. Both
        // engines conform to `FrameRecognitionEngine` from the images module.
        .target(name: "GlyphRecognitionCxx",
                dependencies: ["GlyphRecognition", "GlyphRecognitionImages", "GlyphCoreCxx"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "GlyphRecognize", dependencies: ["GlyphRecognition", "GlyphRecognitionImages"]),
        // Replays captured frames through the whole live pipeline, including
        // the slot-indicator reader and header text recognition, so the
        // boundaries under test are derived from pixels rather than annotated.
        .executableTarget(name: "GlyphReplay",
                          dependencies: ["GlyphRecognition", "GlyphRecognitionImages", "GlyphRecognitionCxx"]),
        .testTarget(
            name: "GlyphRecognitionTests",
            // GlyphReplay is here for its ablation switches, which exist only
            // in the replay and are tested like any other pipeline rule.
            dependencies: ["GlyphRecognition", "GlyphRecognitionImages", "GlyphCoreCxx", "GlyphRecognitionCxx",
                           "GlyphReplay"],
            // Bundled so the tests find them on a runner with no checkout --
            // see ReferenceData.swift.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ],
    cxxLanguageStandard: .cxx17
)
