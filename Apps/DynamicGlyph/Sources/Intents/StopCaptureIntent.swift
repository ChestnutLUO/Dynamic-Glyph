import AppIntents

/// Stop Dynamic Glyph in Shortcuts, Siri and Spotlight: always a stop, never
/// a toggle, and without opening the app. It asks whichever side is
/// capturing to stop, as the Control Center switch's Off does, then waits as
/// long as the switch does to see the capture end, and says only what it
/// saw.
struct StopCaptureIntent: AppIntent {
    static let title = LocalizedStringResource("Stop Dynamic Glyph",
                                               comment: "Shortcuts, Siri and Spotlight: the action that stops reading the screen without opening the app. The same words as the Control Center switch's Off.")
    static let description: IntentDescription? = IntentDescription(
        LocalizedStringResource("Stops reading the screen and ends screen sharing.",
                                comment: "Shortcuts: what Stop Dynamic Glyph does."))

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await Self.run()
        return .result(dialog: IntentDialog(outcome.dialog))
    }

    /// `ToggleGlyphIntent`'s stop, followed by one more reading to decide
    /// what to report. Kept apart so the switch's behaviour can't change
    /// with this action's. Also run by the debug page.
    static func run() async -> StopCaptureOutcome {
        guard let store = ControlCaptureStore.appGroup else {
            return .decide(asked: false, stillOn: false)
        }
        let request = store.requestStop()
        if request.app { BroadcastChannel.post(ControlChannel.stopRequested) }
        if request.broadcast { BroadcastChannel.post(BroadcastChannel.stopRequested) }
        if request.askedAnything {
            let deadline = ContinuousClock.now + ToggleGlyphIntent.stopPatience
            while store.isOn(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let outcome = StopCaptureOutcome.decide(asked: request.askedAnything, stillOn: store.isOn())
        // The switch, if placed, shows what this left.
        ControlChannel.reload()
        return outcome
    }
}
