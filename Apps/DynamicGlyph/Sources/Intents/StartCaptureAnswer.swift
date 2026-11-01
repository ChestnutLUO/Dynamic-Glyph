import Foundation

/// What the app is doing when Shortcuts or Siri asks it to start reading,
/// as Home's Start button sees it.
struct StartCaptureConditions: Equatable {
    /// Capturing, here or in the broadcast extension.
    var isReading: Bool
    /// Waiting for screen sharing, stopping, or first-run setup on screen:
    /// Start would not open the system's sheet now.
    var isGettingReady: Bool
    // Nothing else: Start is never blocked for want of a Glyph list. Without
    // one, capture reads gear only (`GlyphAssistance.isInEffect`).
}

/// What the Start action tells the player. Only `opened` asks the app for
/// screen sharing; every other answer leaves capture as it is, so a second
/// session is never set up. Pure, so each answer can be tested.
enum StartCaptureAnswer: Equatable {
    /// The app is in front and will show the system's screen-sharing sheet.
    /// Nothing is read until the player confirms there.
    case opened
    case alreadyRunning
    case notReady

    init(_ conditions: StartCaptureConditions) {
        if conditions.isReading { self = .alreadyRunning }
        else if conditions.isGettingReady { self = .notReady }
        else { self = .opened }
    }

    /// Whether the app should ask for screen sharing, as Home's Start does.
    var asksForSharing: Bool { self == .opened }

    /// Spoken by Siri and shown in Shortcuts. `opened` never says capture
    /// started: the player still has to confirm in the system's sheet.
    var dialog: LocalizedStringResource {
        switch self {
        case .opened:
            return LocalizedStringResource("Dynamic Glyph is open. Start screen sharing to begin.",
                                           comment: "Siri and Shortcuts, Start Dynamic Glyph: the app opened and asks for screen sharing; nothing is read until the player confirms.")
        case .alreadyRunning:
            return LocalizedStringResource("Dynamic Glyph is already running.",
                                           comment: "Siri and Shortcuts, Start Dynamic Glyph: the screen is already being read, so nothing new was started.")
        case .notReady:
            return LocalizedStringResource("Dynamic Glyph is still getting ready. Try again in a moment.",
                                           comment: "Siri and Shortcuts, Start Dynamic Glyph: the app is waiting for screen sharing, stopping, or in first-run setup.")
        }
    }
}
