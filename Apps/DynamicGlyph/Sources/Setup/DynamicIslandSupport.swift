import Foundation

/// Whether this iPhone has a Dynamic Island, as far as its model says.
///
/// iOS offers no API for this, and Apple's developer support declines to give
/// one. The model identifier is the only honest source, and only for models
/// that existed when this table was written: anything newer is `unknown`, and
/// setup asks the player rather than guessing.
enum DynamicIslandSupport: Equatable {
    case hasIsland, noIsland, unknown

    /// Identifiers from AppleDB, checked 2026-09-23.
    private static let island: Set<String> = [
        "iPhone15,2", "iPhone15,3",                             // 14 Pro, 14 Pro Max
        "iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2", // 15, 15 Plus, 15 Pro, 15 Pro Max
        "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4", // 16 Pro, 16 Pro Max, 16, 16 Plus
        "iPhone18,1", "iPhone18,2", "iPhone18,3", "iPhone18,4"  // 17 Pro, 17 Pro Max, 17, Air
    ]
    private static let notch: Set<String> = [
        "iPhone17,5", // 16e
        "iPhone18,5"  // 17e
    ]

    static func detect(modelIdentifier: String) -> DynamicIslandSupport {
        if island.contains(modelIdentifier) { return .hasIsland }
        if notch.contains(modelIdentifier) { return .noIsland }
        // iPad and iPod touch have no Island. Every iPhone before the 14 Pro,
        // the 14 and the SE included, reports a major version of 14 or lower.
        if modelIdentifier.hasPrefix("iPad") || modelIdentifier.hasPrefix("iPod") { return .noIsland }
        if modelIdentifier.hasPrefix("iPhone"),
           let major = Int(modelIdentifier.dropFirst("iPhone".count).prefix { $0 != "," }), major <= 14 {
            return .noIsland
        }
        return .unknown
    }

    static var current: DynamicIslandSupport { detect(modelIdentifier: currentModelIdentifier) }

    /// The simulator reports the Mac's architecture as its machine name; the
    /// device it simulates is in its environment instead.
    static var currentModelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
