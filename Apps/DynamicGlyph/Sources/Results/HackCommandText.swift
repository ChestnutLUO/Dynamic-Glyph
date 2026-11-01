import Foundation
import GlyphRecognition

extension HackCommandSummary {
    /// One line for a hack's card: what was seen, that none was, or that it
    /// may have been missed. Nil is a hack saved before commands were read.
    static func cardText(_ commands: HackCommandSummary?) -> String {
        guard let commands else {
            return String(localized: "Commands not read", comment: "Hack card: saved before the app read command notices.")
        }
        let speed = commands.presentation, keys = commands.gear
        if commands.mode != .drone, speed.status == .noCommandObserved, keys.status == .noCommandObserved {
            return String(localized: "No command", comment: "Hack card: no command notice was seen before this hack.")
        }
        let speedText: String = switch (speed.status, speed.effective) {
        case (.confirmed, .simple): String(localized: "Simple hack")
        case (.confirmed, .complex): String(localized: "Complex hack")
        case (.noCommandObserved, _): String(localized: "No speed command", comment: "Hack card: no SIMPLE or COMPLEX HACK notice was seen.")
        default: String(localized: "Speed command uncertain")
        }
        let keyText: String = if commands.mode == .drone {
            String(localized: "Drone · key commands don't apply")
        } else {
            switch (keys.status, keys.effective) {
            case (.confirmed, .requestKey): String(localized: "Request key")
            case (.confirmed, .noKey): String(localized: "No key")
            case (.confirmed, .keysOnly): String(localized: "Keys only")
            case (.noCommandObserved, _): String(localized: "No key command", comment: "Hack card: no REQUEST, NO or ONLY KEY notice was seen.")
            default: String(localized: "Key command uncertain")
            }
        }
        return "\(speedText) · \(keyText)"
    }
}
