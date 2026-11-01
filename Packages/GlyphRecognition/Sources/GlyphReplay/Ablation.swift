import GlyphRecognition

/// One pipeline component the replay can switch off, to measure what it
/// contributes. Every ablation removes behaviour; none adds any, and with the
/// empty set the replay is exactly the live pipeline.
enum Ablation: String, CaseIterable, Sendable {
    /// Vision header text: no frame carries a header reading.
    case header
    /// The slot indicator strip: no reading and no rejection reason.
    case strip
    /// The input countdown bar is never seen.
    case timer
    /// A calibration is trusted without checking it against the game layout.
    case layoutCheck = "layout-check"
    /// Every frame fits the array afresh instead of reusing a fit acquired on
    /// an empty array.
    case calibrationCache = "calibration-cache"
    /// A geometric match with excessive unexplained bright ink still counts.
    case inkCheck = "ink-check"
    /// One sample of a shape makes it stable.
    case stability
    /// One strip reading establishes the slot count.
    case slotVotes = "slot-votes"
    /// Presentation cannot be established from the indicator strip alone.
    case indicatorPhase = "indicator-phase"
    /// The last slot is never closed by its released indicator.
    case lastSlotRelease = "last-slot-release"

    static func parse(_ list: String) throws -> Set<Ablation> {
        var result: Set<Ablation> = []
        for name in list.split(separator: ",").map(String.init) where !name.isEmpty {
            guard let ablation = Ablation(rawValue: name) else {
                throw ReplayError.usage("unknown ablation \(name); known: "
                                        + allCases.map(\.rawValue).joined(separator: ", "))
            }
            result.insert(ablation)
        }
        return result
    }

    /// The strip reader reports the countdown bar too, and `FrameEvidence`
    /// merges that in, so hiding the timer has to reach the reading as well.
    static func reading(_ reading: SlotStripReading, under ablations: Set<Ablation>) -> SlotStripReading {
        guard ablations.contains(.timer), reading.hasInputTimerBar else { return reading }
        return SlotStripReading(slotCount: reading.slotCount, highlightedIndex: reading.highlightedIndex,
                                markerCentersX: reading.markerCentersX, hasInputTimerBar: false,
                                isPartlyCovered: reading.isPartlyCovered)
    }

    static func policy(for ablations: Set<Ablation>) -> PresentationTracker.Policy {
        var policy = PresentationTracker.Policy()
        if ablations.contains(.stability) {
            policy.minimumStableSamples = 1
            policy.minimumStableInterval = 0
        }
        if ablations.contains(.slotVotes) { policy.slotCountVotesRequired = 1 }
        if ablations.contains(.indicatorPhase) { policy.entersPresentationFromIndicators = false }
        if ablations.contains(.lastSlotRelease) { policy.closesLastSlotOnRelease = false }
        return policy
    }
}

enum ReplayError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self {
        case .usage(let message): return message
        }
    }
}

/// Re-derives the shape evidence of one observation with the recognizer's
/// shape ablations applied, using only what the observation exposes.
struct ShapeAblator {
    let ablations: Set<Ablation>

    func evidence(for observation: GlyphFrameObservation) -> ShapeEvidence {
        // The ink verdict only ever downgrades an exact geometric match, so
        // undoing it needs nothing the observation does not already expose.
        guard ablations.contains(.inkCheck), observation.state == .unexplainedInk else {
            return ShapeEvidence(observation)
        }
        let matches = observation.exactMatches
        return ShapeEvidence(kind: matches.count == 1 ? .uniqueVisibleShape : .ambiguousShape,
                             glyph: matches.count == 1 ? matches.first : nil,
                             edges: observation.edges, extensions: observation.extensions)
    }
}
