import AppIntents

/// Start Dynamic Glyph in Shortcuts, Siri and Spotlight. It opens the app,
/// which asks for screen sharing the way Home's Start does, through the same
/// request the Control Center switch leaves (`ControlStartInbox`). Capture
/// never starts by itself: the player still confirms in the system's sheet,
/// and closing that sheet leaves the app idle, as it does after Home's Start.
///
/// App only, and separate from `StartGlyphIntent`, so the Control Center
/// switch keeps its own hidden action unchanged.
struct StartCaptureIntent: AppIntent {
    /// The switch's words and comment, so the one catalog entry serves both.
    static let title = LocalizedStringResource("Start Dynamic Glyph",
                                               comment: "The Control Center switch's action while it is off: opens the app to start reading the screen.")
    static let description: IntentDescription? = IntentDescription(
        LocalizedStringResource("Opens Dynamic Glyph to start reading the screen. You confirm screen sharing each time.",
                                comment: "Shortcuts: what Start Dynamic Glyph does."))
    /// The system's screen-sharing sheet can only be presented by the app in front.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await Self.run()
        return .result(dialog: IntentDialog(answer.dialog))
    }

    /// Asks for screen sharing only when Home's Start would; otherwise says
    /// why not and leaves capture as it is. Also run by the debug page.
    @MainActor
    static func run() async -> StartCaptureAnswer {
        let conditions = await StartCaptureContext.shared.conditions()
        let answer = StartCaptureAnswer(conditions)
        if answer.asksForSharing { ControlStartInbox.shared.post() }
        return answer
    }
}
