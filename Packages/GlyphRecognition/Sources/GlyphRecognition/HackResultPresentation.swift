import Foundation

/// Wording for a hack's conclusion, shared by every surface that shows one so
/// they cannot describe the same result differently. An unknown value is
/// always said to be unknown: never 0%, never a rejection.
extension HackResultSummary {
    public var headline: String {
        switch state {
        case .awaiting:
            return String(localized: "Waiting for the result screen…", bundle: #bundle,
                          comment: "Hack result card while the hack is still in progress.")
        case .complete:
            return String(localized: "Result read", bundle: #bundle,
                          comment: "Hack result card: every field was read from the game's result screen.")
        case .partial:
            return String(localized: "Result partly read", bundle: #bundle,
                          comment: "Hack result card: some fields on the game's result screen could not be read.")
        case .notObserved:
            return closeReason == "captureStopped"
                ? String(localized: "Stopped before the result screen", bundle: #bundle,
                         comment: "Hack result card: screen capture stopped before the game showed its result.")
                : String(localized: "No result screen seen", bundle: #bundle,
                         comment: "Hack result card: the game's result screen never appeared, for example after pressing Done early.")
        }
    }

    public var glyphCountLine: String {
        String(localized: "\(slots.count) Glyphs", bundle: #bundle,
               comment: "Hack result card: how many Glyphs the hack had.")
    }

    /// As the game prints it. Nil when the value was never read.
    public static func percentText(_ bonus: Bonus?) -> String? {
        bonus.map { "\($0.percent)%" }
    }

    public var hasProvisionalBonus: Bool {
        hackingBonus?.isFinal == false || speedBonus?.isFinal == false
    }

    public static func outcomeLabel(_ outcome: GameSlotOutcome) -> String {
        switch outcome {
        case .accepted:
            return String(localized: "Accepted", bundle: #bundle,
                          comment: "Under a Glyph on the hack result card: the game accepted this drawing.")
        case .rejected:
            return String(localized: "Rejected", bundle: #bundle,
                          comment: "Under a Glyph on the hack result card: the game rejected this drawing.")
        case .unknown:
            return String(localized: "Unread", bundle: #bundle,
                          comment: "Under a Glyph on the hack result card: the game's verdict could not be read.")
        }
    }

    public func accessibilityLabel(slot index: Int) -> String {
        let slot = slots[index]
        let number = index + 1
        let name = slot.glyph ?? "?"
        switch slot.outcome {
        case .accepted:
            return String(localized: "Glyph \(number), \(name): accepted by the game", bundle: #bundle,
                          comment: "VoiceOver. First placeholder: one-based slot number. Second: untranslated Glyph name.")
        case .rejected:
            return String(localized: "Glyph \(number), \(name): rejected by the game", bundle: #bundle,
                          comment: "VoiceOver. First placeholder: one-based slot number. Second: untranslated Glyph name.")
        case .unknown:
            return String(localized: "Glyph \(number), \(name): the game's verdict couldn't be read", bundle: #bundle,
                          comment: "VoiceOver. First placeholder: one-based slot number. Second: untranslated Glyph name.")
        }
    }

    /// One line per slot where our input check and the game disagree. Gaps
    /// in our own coverage are not disagreements and are not listed.
    public var disagreementLines: [String] {
        slots.indices.compactMap { index in
            let slot = slots[index]
            guard slot.comparison == .disagreement else { return nil }
            let number = index + 1
            switch slot.outcome {
            case .accepted:
                return String(localized: "Glyph \(number): the game accepted it, the app's check warned", bundle: #bundle,
                              comment: "Hack result card. Placeholder: one-based slot number.")
            case .rejected:
                return String(localized: "Glyph \(number): the game rejected it, the app's check matched", bundle: #bundle,
                              comment: "Hack result card. Placeholder: one-based slot number.")
            case .unknown:
                return nil
            }
        }
    }
}
