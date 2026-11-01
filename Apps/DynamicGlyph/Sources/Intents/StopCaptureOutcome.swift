import Foundation

/// What the Stop action tells the player, from what it saw in the App Group.
/// Pure, so it can be tested that a stop is reported only when observed.
enum StopCaptureOutcome: Equatable {
    /// Nothing was capturing, so nothing was asked.
    case notRunning
    /// Asked, and the capture was seen to end.
    case stopped
    /// Still reading when the wait ran out, or reading with nothing that
    /// could be asked: the stop can't be confirmed.
    case unconfirmed

    /// `asked`: a stop request reached the app or the broadcast.
    /// `stillOn`: the capture still reads as on after the wait.
    static func decide(asked: Bool, stillOn: Bool) -> StopCaptureOutcome {
        // Also when nothing could be asked: something still reads as on, so
        // "isn't running" would be false and "stopped" unobserved.
        if stillOn { return .unconfirmed }
        return asked ? .stopped : .notRunning
    }

    var dialog: LocalizedStringResource {
        switch self {
        case .notRunning:
            return LocalizedStringResource("Dynamic Glyph isn't running.",
                                           comment: "Siri and Shortcuts, Stop Dynamic Glyph: the screen wasn't being read, so nothing was stopped.")
        case .stopped:
            return LocalizedStringResource("Dynamic Glyph stopped.",
                                           comment: "Siri and Shortcuts, Stop Dynamic Glyph: the stop was asked for and the capture was seen to end.")
        case .unconfirmed:
            return LocalizedStringResource("Asked Dynamic Glyph to stop, but couldn't confirm it. Check the app.",
                                           comment: "Siri and Shortcuts, Stop Dynamic Glyph: the screen still read as being read when the wait ended.")
        }
    }
}
