import Foundation

/// Why the floating window cannot be turned off, where it cannot.
enum FloatingWindowRequirement {
    static let explanation = LocalizedStringResource(
        "On this version of iOS, Dynamic Glyph keeps watching the screen only while the floating window is open.",
        comment: "Under the floating-window switch, and in setup, on iOS 18 to 26 where the window cannot be turned off.")
}
