import Foundation

/// How one slot should be drawn, and what kind of evidence it rests on.
///
/// This is the single mapping from the model to a picture. It lives in the
/// recognition core rather than in a renderer because three surfaces consume it
/// — the Picture in Picture window, the in-app tiles and the Live Activity —
/// and the widget extension links only this module. A second reading of the
/// model somewhere else is how surfaces start disagreeing about what was
/// observed.
public enum TileStyle: Sendable, Equatable {
    /// Held across an independently verified boundary.
    case confirmed(GlyphID)
    /// Visible right now, not yet part of the sequence.
    case observing(GlyphID)
    /// Retained from a presentation with unreadable slot boundaries/positions.
    case inferred(GlyphID)
    /// From the sequence table; never seen.
    case predicted(GlyphID)
    /// Several Glyphs could be here and the table does not choose.
    case alternatives(Int)
    /// Evidence existed and did not settle.
    case uncertain
    /// The boundary passed with nothing legible.
    case missing
    /// Not reached, and nothing predicts it.
    case pending

    /// The shape to draw, if there is one.
    public var glyph: GlyphID? {
        switch self {
        case .confirmed(let id), .observing(let id), .inferred(let id), .predicted(let id): return id
        case .alternatives, .uncertain, .missing, .pending: return nil
        }
    }

    /// Anything not actually observed is drawn dashed. Line style, not colour
    /// alone, has to carry this: colour is the first thing a small, dim or
    /// colour-blind-unfriendly rendering loses.
    public var isDashed: Bool {
        if case .confirmed = self { return false }
        return true
    }

    /// Glyph names are the game's own and are shown untranslated.
    public var caption: String {
        switch self {
        case .confirmed(let id), .observing(let id), .inferred(let id), .predicted(let id): return id.name
        case .alternatives(let count):
            return String(localized: "\(count) options", bundle: #bundle,
                          comment: "Slot caption: this many Glyphs could still fill the slot.")
        case .uncertain:
            return String(localized: "Unclear", bundle: #bundle,
                          comment: "Slot caption: something was seen but it did not settle on one Glyph.")
        case .missing:
            return String(localized: "Missed", bundle: #bundle,
                          comment: "Slot caption: the slot passed with nothing readable.")
        case .pending: return "—"
        }
    }
}

/// The Glyphs the player still has to draw, starting with the one the game is
/// waiting for.
public struct UpcomingGuidance: Sendable, Equatable {
    /// Zero-based slot the first entry refers to.
    public let firstSlotIndex: Int
    public let styles: [TileStyle]

    public init(firstSlotIndex: Int, styles: [TileStyle]) {
        self.firstSlotIndex = firstSlotIndex
        self.styles = styles
    }
}

extension GlyphDisplaySnapshot {
    /// Every slot, in order, as the thing a renderer should draw.
    public var tileStyles: [TileStyle] {
        let count = max(slots.count, expectedSlotCount ?? 0)
        guard count > 0 else { return [] }
        let observed = outlook.observed.count
        return (0..<count).map { index in
            let slot = index < slots.count ? slots[index] : nil
            switch slot?.status {
            case .confirmed:
                if let glyph = slot?.glyph { return .confirmed(glyph) }
                return .uncertain
            case .inferred:
                if let glyph = slot?.glyph { return .inferred(glyph) }
                return .uncertain
            case .observing:
                if acceptance.isTracking, index == currentSlotIndex, let visible = provisionalGlyph {
                    return .observing(visible)
                }
                return .pending
            case .missing:
                return .missing
            case .uncertain:
                return .uncertain
            case .pending, .none:
                // Nothing observed here, so anything shown is a prediction and
                // is drawn as one.
                guard index >= observed else { return .pending }
                let offset = index - observed
                if outlook.state == .resolved, offset < outlook.predictedSuffix.count {
                    return .predicted(outlook.predictedSuffix[offset])
                }
                if offset < outlook.suffixAlternatives.count {
                    let choices = outlook.suffixAlternatives[offset]
                    if choices.count == 1 { return .predicted(choices[0]) }
                    return .alternatives(choices.count)
                }
                return .pending
            }
        }
    }

    /// The second caption line: what kind of evidence a tile rests on.
    ///
    /// A shape that is merely visible may still be the beginning of a longer
    /// one — `see` grows into `advance` — so while it is only being observed,
    /// how many ways it could still grow is part of the honest answer.
    public func note(for style: TileStyle) -> String? {
        switch style {
        case .confirmed:
            return String(localized: "Observed", bundle: #bundle,
                          comment: "Slot note: this Glyph was seen in the game's sequence.")
        case .inferred:
            return String(localized: "Inferred · position unverified", bundle: #bundle,
                          comment: "Slot note: seen, but its place in the sequence was guessed.")
        case .observing:
            return provisionalExtensionCount > 0
                ? String(localized: "Observing… +\(provisionalExtensionCount) longer", bundle: #bundle,
                         comment: "Slot note: shape still visible; the number is how many longer Glyphs it could grow into.")
                : String(localized: "Observing…", bundle: #bundle,
                         comment: "Slot note: the shape is still being shown.")
        case .predicted, .alternatives:
            return String(localized: "Predicted", bundle: #bundle,
                          comment: "Slot note: taken from the sequence list, not seen.")
        case .uncertain:
            return String(localized: "Not settled", bundle: #bundle,
                          comment: "Slot note: the evidence did not settle on one Glyph.")
        case .missing:
            return String(localized: "No evidence", bundle: #bundle,
                          comment: "Slot note: nothing was seen for this slot.")
        case .pending: return nil
        }
    }

    /// What to tell the player to draw next, or nothing at all.
    ///
    /// A window onto `tileStyles`, never a second classification: the slot the
    /// indicator points at already has a style, and re-deriving one here is how
    /// the Island would end up disagreeing with the window beside it.
    ///
    /// Returns nil — and the surfaces fall back to a plain status — in every
    /// case where the instruction would be stronger than the evidence:
    ///
    /// - not in the input phase, so nothing is being drawn;
    /// - the gold indicator was not read, or was read too long ago;
    /// - the indicators are obscured, by a banner or by the Picture in Picture window;
    /// - the display is only claiming provisional shapes, where "draw this"
    ///   would assert more than the display itself does;
    /// - the slot count changed mid-hack, so indicator index and slot index no
    ///   longer line up;
    /// - the indicator points past the slots we know about, which is a
    ///   contradiction rather than guidance;
    /// - capture has stopped;
    /// - or the window holds nothing nameable.
    public func upcomingGuidance(limit: Int = 2,
                                 maximumIndicatorAge: Double = 0.75) -> UpcomingGuidance? {
        guard state == .input, liveness == .live, acceptance.isTracking,
              !slotCountConflict, !indicatorsObstructed,
              !slots.contains(where: { $0.status == .inferred }),
              let index = inputSlotIndex else { return nil }
        if let observed = inputSlotObservedTime, sourceFrameTime - observed > maximumIndicatorAge {
            return nil
        }
        let styles = tileStyles
        guard index >= 0, index < styles.count else { return nil }
        let window = Array(styles[index..<min(index + max(1, limit), styles.count)])
        // `observing` should be unreachable once input begins, because entering
        // it closes the open slot. Refused anyway: showing the player their own
        // stroke back as an instruction is the worst failure available here.
        guard !window.contains(where: { if case .observing = $0 { return true } else { return false } })
        else { return nil }
        let sayable = window.contains { style in
            if style.glyph != nil { return true }
            if case .alternatives = style { return true }
            return false
        }
        guard sayable else { return nil }
        return UpcomingGuidance(firstSlotIndex: index, styles: window)
    }
}
