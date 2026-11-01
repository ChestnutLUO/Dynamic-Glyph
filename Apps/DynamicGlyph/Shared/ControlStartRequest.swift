import Foundation

/// A start asked for by the Control Center button, waiting until the app can
/// act on it.
///
/// The button only opens the app; the app then takes the path Home's Start
/// takes, so the system's screen-sharing confirmation appears at once. The
/// request is kept until the app is in front, which on a cold launch is after
/// the intent has run, and is acted on at most once. Pure, so every launch
/// order can be tested.
struct ControlStartRequest: Equatable {
    /// What the app is doing when it looks at the request.
    struct AppState: Equatable {
        enum Capture: Equatable {
            case idle
            /// Waiting for the player to confirm screen sharing.
            case waitingForSharing
            /// Capturing, or stopping a capture.
            case running
        }

        /// In front and showing its screens, so a sheet can be presented.
        var isActive: Bool
        /// First-run setup is on screen, which Start must not interrupt.
        var isSettingUp: Bool
        var capture: Capture
    }

    /// Why a request only brought the app forward.
    enum Skip: Equatable {
        case setup
        case waitingForSharing
        case running
        /// A second tap right after a start: one sheet at a time.
        case repeated
        /// Asked for too long ago to still be what the player wants.
        case expired
    }

    enum Outcome: Equatable {
        /// Nothing was asked for.
        case none
        /// Not in front yet: the request is kept.
        case wait
        /// Ask for screen sharing, as Home's Start does.
        case start
        /// The app is in front, and that is all.
        case skip(Skip)
    }

    /// A request the app could not act on for this long is dropped, so a
    /// sheet never appears long after the tap that asked for it.
    static let patience: TimeInterval = 30
    /// Taps this close after a start are the same request.
    static let repeatInterval: TimeInterval = 2

    /// When the latest unanswered request arrived, in system uptime.
    private(set) var requestedAt: TimeInterval?
    private(set) var startedAt: TimeInterval?

    var isPending: Bool { requestedAt != nil }

    /// Several taps before the app looks are one request.
    mutating func receive(at now: TimeInterval) {
        requestedAt = now
    }

    mutating func resolve(_ app: AppState, at now: TimeInterval) -> Outcome {
        guard let requestedAt else { return .none }
        if now - requestedAt > Self.patience {
            self.requestedAt = nil
            return .skip(.expired)
        }
        guard app.isActive else { return .wait }
        self.requestedAt = nil
        if app.isSettingUp { return .skip(.setup) }
        switch app.capture {
        case .running: return .skip(.running)
        case .waitingForSharing: return .skip(.waitingForSharing)
        case .idle: break
        }
        if let startedAt, now - startedAt < Self.repeatInterval { return .skip(.repeated) }
        startedAt = now
        return .start
    }
}
