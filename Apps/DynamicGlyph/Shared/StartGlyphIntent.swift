import AppIntents

/// The Control Center switch's start, run by `ToggleGlyphIntent` when the
/// switch is off: it opens the app, which then asks for screen sharing the
/// way Home's Start does. It never starts capture by itself; the player still
/// confirms in the system's sheet.
///
/// Compiled into the app and the widget extension both: the extension's
/// control names it, and because it opens the app, the system performs it in
/// the app's process, where the home screen picks the request up.
struct StartGlyphIntent: AppIntent {
    static let title = LocalizedStringResource("Start Dynamic Glyph",
                                               comment: "The Control Center switch's action while it is off: opens the app to start reading the screen.")
    static let openAppWhenRun = true
    /// Offered only through the Control Center switch, not in Shortcuts or Spotlight.
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        ControlStartInbox.shared.post()
        return .result()
    }
}
