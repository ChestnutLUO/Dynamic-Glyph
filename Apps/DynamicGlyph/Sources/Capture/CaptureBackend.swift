import Foundation

/// Where a capture session's frames and sound go. The engine decides this
/// only once the player has agreed to share the screen, so nothing is
/// recorded for a session that never starts.
struct CaptureSinks {
    let recognition: LiveGlyphOutput
    /// The serial queue `recognition` is confined to.
    let recognitionQueue: DispatchQueue
    /// The recording that wants the device's sound, if one does.
    let soundRecorder: DebugScreenRecorder?
}

/// Why a capture did not start, or stopped without being asked to. The
/// technical detail goes to the session log through `captureBackendNote`;
/// this is what the engine needs to decide what to tell the player.
enum CaptureBackendFailure: Equatable {
    /// The player dismissed the consent sheet.
    case consentCancelled
    /// The consent sheet itself failed.
    case consentFailed
    /// Consent was given, but the capture could not be set up or started.
    case startFailed
    /// A running capture ended on its own: the player stopped sharing, or iOS did.
    case interrupted
    /// The player turned the Control Center switch off while the app was not
    /// listening, so the broadcast ended without the app's Stop. Nothing for
    /// the player to do about it.
    case stoppedFromControlCenter

    /// Whether the session has to be torn down. The consent sheet can report
    /// again while a capture is running; its dismissal or failure then leaves
    /// that capture alone.
    func endsSession(whileCapturing isCapturing: Bool) -> Bool {
        switch self {
        case .consentCancelled, .consentFailed: return !isCapturing
        case .startFailed, .interrupted, .stoppedFromControlCenter: return true
        }
    }

    /// What the player is told, if anything. A stop the player asked for,
    /// from the sheet or the Control Center switch, needs no message.
    var problem: String? {
        switch self {
        case .consentCancelled, .stoppedFromControlCenter:
            return nil
        case .consentFailed:
            return String(localized: "Screen sharing couldn't start. Please try again.",
                          comment: "Shown when the screen-sharing sheet fails.")
        case .startFailed:
            return String(localized: "Couldn't start watching the screen. Please try again.",
                          comment: "Shown when screen capture fails to start.")
        case .interrupted:
            return String(localized: "Screen sharing stopped. Tap Start to pick up again.",
                          comment: "Shown when iOS or the player ends screen sharing.")
        }
    }

    /// Whether a running capture is already over when this is reported.
    var endsRunningCapture: Bool { self == .interrupted || self == .stoppedFromControlCenter }

    /// Why a broadcast the app was attached to ended, from what its extension
    /// left in the ring. While the app is attached, only the Control Center
    /// switch asks the extension to stop: the app's own Stop detaches first.
    /// A killed extension leaves no reason, so that is an interruption.
    static func broadcastEnded(_ reason: FrameRingEndReason?) -> CaptureBackendFailure {
        reason == .stopRequested ? .stoppedFromControlCenter : .interrupted
    }
}

@MainActor
protocol CaptureBackendDelegate: AnyObject {
    /// Consent was given. Returns where frames go, or nil to abandon the
    /// start, in which case the engine has already said why.
    func captureBackendWillStart() -> CaptureSinks?
    func captureBackendDidStart()
    func captureBackend(didFail failure: CaptureBackendFailure)
    /// A line for the session log and, when given, the diagnostics status.
    func captureBackendNote(_ message: String, status: String?)
}

/// Obtains the player's consent, runs the capture, and hands frames to the
/// engine's sinks. Session state, recognition, recording and the displays
/// stay with the engine, whichever framework delivers the frames.
@MainActor
protocol CaptureBackend: AnyObject {
    var delegate: CaptureBackendDelegate? { get set }
    /// Whether consent can be asked for right now.
    var isAvailable: Bool { get }
    /// Whether a capture has been set up and not yet stopped or reset.
    var hasSession: Bool { get }
    /// Whether the app only keeps running over the game while the floating
    /// window is open, so it cannot be turned off.
    var requiresFloatingWindow: Bool { get }
    func requestConsent()
    /// Stops a running capture at once: from this call on, the backend reports
    /// nothing more. The task finishes when the source has stopped delivering
    /// frames.
    @discardableResult
    func stop() -> Task<Void, Never>
    /// Forgets a capture that never started or has already ended, without
    /// waiting for the source to stop.
    func reset()
}
