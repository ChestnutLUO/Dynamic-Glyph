import AppIntents

/// What the Control Center switch runs. Off to on is Home's Start, through
/// `StartGlyphIntent`, which opens the app for the system's screen-sharing
/// confirmation. On to off stops the capture without opening the app.
///
/// Stopping reaches whichever side is capturing, so it works in the app's
/// process or the widget extension's: on iOS 27 the app, through a request
/// in the App Group and a Darwin notification; on iOS 18-26 the broadcast
/// extension, through the frame ring it watches itself, so the broadcast
/// ends even while the app is suspended.
struct ToggleGlyphIntent: SetValueIntent {
    static let title = LocalizedStringResource("Dynamic Glyph",
                                               comment: "The Control Center switch's name, the same in every language.")
    /// Offered only as the Control Center switch, not in Shortcuts or Spotlight.
    static let isDiscoverable = false

    @Parameter(title: LocalizedStringResource("Dynamic Glyph",
                                              comment: "The Control Center switch's name, the same in every language."))
    var value: Bool

    /// The switch shows On only while the screen is actually read, and the
    /// system reads it again once this returns, so a stop waits this long for
    /// the capture to end rather than flash Off and back.
    static let stopPatience: Duration = .milliseconds(2500)

    func perform() async throws -> some IntentResult & OpensIntent {
        // One result type for both answers, as `perform` requires: starting
        // opens the app through `StartGlyphIntent`; stopping opens nothing.
        var result: IntentResultContainer<Never, StartGlyphIntent, Never, Never> =
            .result(opensIntent: StartGlyphIntent())
        guard !value else {
            // Off until sharing truly starts; read again so a stale On clears.
            ControlChannel.reload()
            return result
        }
        result.opensIntent = nil
        guard let store = ControlCaptureStore.appGroup else { return result }
        let outcome = store.requestStop()
        if outcome.app { BroadcastChannel.post(ControlChannel.stopRequested) }
        if outcome.broadcast { BroadcastChannel.post(BroadcastChannel.stopRequested) }
        if outcome.askedAnything {
            let deadline = ContinuousClock.now + Self.stopPatience
            while store.isOn(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        ControlChannel.reload()
        return result
    }
}
