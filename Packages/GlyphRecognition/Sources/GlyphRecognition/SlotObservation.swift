/// One position in the presented sequence, whatever became of it.
///
/// A slot that was missed keeps its place. Collapsing the sequence to the
/// Glyphs that happened to be recognized would renumber everything after the
/// gap, and a renumbered sequence is worse than an admitted hole: the player
/// would draw the right shapes in the wrong order.
public struct SlotObservation: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// The slot exists but the game has not reached it.
        case pending
        /// The slot is on screen now; evidence is still tentative.
        case observing
        /// A stable shape held across an independently verified boundary.
        case confirmed
        /// Seen during presentation, but its boundary/position was inferred
        /// while indicators were unreadable. Never a predictor input.
        case inferred
        /// The boundary passed with no shape evidence at all.
        case missing
        /// Evidence existed but did not settle on one answer.
        case uncertain
    }

    public let index: Int
    public var status: Status
    /// Set for confirmed or inferred observations; status carries the distinction.
    public var glyph: GlyphID?
    /// Stable shapes that were seen and not chosen, kept for review.
    public var alternatives: [GlyphID]
    public var firstSampleTime: Double?
    public var lastSampleTime: Double?
    /// Independent frames supporting the chosen answer.
    public var sampleCount: Int
    /// The boundary that closed this slot, or why it could not be closed.
    public var boundaryReason: String?

    public init(index: Int, status: Status = .pending, glyph: GlyphID? = nil,
                alternatives: [GlyphID] = [], firstSampleTime: Double? = nil,
                lastSampleTime: Double? = nil, sampleCount: Int = 0,
                boundaryReason: String? = nil) {
        self.index = index
        self.status = status
        self.glyph = glyph
        self.alternatives = alternatives
        self.firstSampleTime = firstSampleTime
        self.lastSampleTime = lastSampleTime
        self.sampleCount = sampleCount
        self.boundaryReason = boundaryReason
    }

    /// Closed one way or another; no further evidence will be accepted.
    public var isSettled: Bool {
        status == .confirmed || status == .inferred || status == .missing || status == .uncertain
    }
}

/// What the tracker did with a frame, in enough detail to review a wrong
/// answer afterwards. Every commit and every refusal produces one of these.
public struct TrackingEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case phaseChanged
        case hackStarted
        case slotAdvanced
        case slotCommitted
        case slotInferred
        case slotMissing
        case slotUncertain
        case evidenceInvalidated
        case slotCountConflict
        case sequenceFrozen
        case hackCompleted
        case staleEvidenceRejected
    }

    public let kind: Kind
    public let time: Double
    public let hackID: Int
    public let slotIndex: Int?
    public let glyph: GlyphID?
    public let reason: String
    public let sampleCount: Int

    public init(kind: Kind, time: Double, hackID: Int, slotIndex: Int? = nil,
                glyph: GlyphID? = nil, reason: String, sampleCount: Int = 0) {
        self.kind = kind
        self.time = time
        self.hackID = hackID
        self.slotIndex = slotIndex
        self.glyph = glyph
        self.reason = reason
        self.sampleCount = sampleCount
    }
}
