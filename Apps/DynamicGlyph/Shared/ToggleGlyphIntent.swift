import AppIntents

/// What the Control Center switch runs from iOS 18.2. Off to on is Home's
/// Start, through `StartGlyphIntent`, which opens the app for the system's
/// screen-sharing confirmation. On to off stops the capture without opening
/// the app.
///
/// Stopping reaches whichever side is capturing, so it works in the app's
/// process or the widget extension's: on iOS 27 the app, through a request
/// in the App Group and a Darwin notification; on iOS 18-26 the broadcast
/// extension, through the frame ring it watches itself, so the broadcast
/// ends even while the app is suspended.
///
/// iOS 18.0 and 18.1 run `LegacyToggleGlyphIntent` instead (`StartControl`).
@available(iOS 18.2, *)
struct ToggleGlyphIntent: SetValueIntent {
    static let title = LocalizedStringResource("Dynamic Glyph",
                                               comment: "The Control Center switch's name, the same in every language.")
    /// Offered only as the Control Center switch, not in Shortcuts or Spotlight.
    static let isDiscoverable = false

    @Parameter(title: LocalizedStringResource("Dynamic Glyph",
                                              comment: "The Control Center switch's name, the same in every language."))
    var value: Bool

    func perform() async throws -> some IntentResult & OpensIntent {
        // One result type for both answers: iOS 18.2's
        // `result(opensIntent:)` has the type of a plain `.result()`.
        guard !value else {
            // Off until sharing truly starts; read again so a stale On clears.
            ControlChannel.reload()
            return .result(opensIntent: StartGlyphIntent())
        }
        // A result that never held an intent. One built with
        // `.result(opensIntent:)` keeps opening it even after its
        // `opensIntent` is set to nil: the system still brought the app
        // forward and ran `StartGlyphIntent`, so a stop showed the
        // screen-sharing sheet again (1.2).
        await ControlSwitchStop.run()
        return .result()
    }
}

/// The switch's action on iOS 18.0 and 18.1, which have no result that opens
/// an intent only sometimes. Off to on opens the app as `ToggleGlyphIntent`
/// does; on to off stops, but the result still names `StartGlyphIntent`, so
/// the app comes forward and asks for sharing again. Accepted there: a switch
/// that could not start at all would be worse.
///
/// Same title and parameter as `ToggleGlyphIntent`; never discoverable.
struct LegacyToggleGlyphIntent: SetValueIntent {
    static let title = LocalizedStringResource("Dynamic Glyph",
                                               comment: "The Control Center switch's name, the same in every language.")
    /// Offered only as the Control Center switch, not in Shortcuts or Spotlight.
    static let isDiscoverable = false

    @Parameter(title: LocalizedStringResource("Dynamic Glyph",
                                              comment: "The Control Center switch's name, the same in every language."))
    var value: Bool

    func perform() async throws -> some IntentResult & OpensIntent {
        var result: IntentResultContainer<Never, StartGlyphIntent, Never, Never> =
            .result(opensIntent: StartGlyphIntent())
        guard !value else {
            // Off until sharing truly starts; read again so a stale On clears.
            ControlChannel.reload()
            return result
        }
        // Ignored by the system from iOS 18.2 (see `ToggleGlyphIntent`).
        result.opensIntent = nil
        await ControlSwitchStop.run()
        return result
    }
}

/// The switch's stop, shared by both actions.
enum ControlSwitchStop {
    /// The switch shows On only while the screen is actually read, and the
    /// system reads it again once the action returns, so a stop waits this
    /// long for the capture to end rather than flash Off and back.
    static let patience: Duration = .milliseconds(2500)

    static func run() async {
        guard let store = ControlCaptureStore.appGroup else { return }
        let outcome = store.requestStop()
        if outcome.app { BroadcastChannel.post(ControlChannel.stopRequested) }
        if outcome.broadcast { BroadcastChannel.post(BroadcastChannel.stopRequested) }
        if outcome.askedAnything {
            let deadline = ContinuousClock.now + patience
            while store.isOn(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        ControlChannel.reload()
    }
}
