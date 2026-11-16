/// The input area's objects as the app and the replay drive them, so either
/// arm, the Swift types here or the C++ ones in `GlyphRecognitionCxx`, can be
/// plugged in. Each protocol is exactly the members `LiveGlyphOutput` and
/// `GlyphReplay` use.

/// `PlayerInputValidator`'s surface.
public protocol PlayerInputValidating {
    init(table: GlyphTable, sessionID: CaptureSessionID)
    var results: [InputCheckResult] { get }
    var revision: Int { get }
    @discardableResult
    mutating func accept<Tracker: PresentationTracking>(_ evidence: FrameEvidence, tracker: Tracker,
                                                        edgeEvidence: [GlyphEdgeEvidence]) -> [InputCheckEvent]
    @discardableResult
    mutating func finish(at time: Double) -> [InputCheckEvent]
}

/// `SequencePredictor`'s surface.
public protocol SequencePredicting {
    init(table: SequenceTable)
    func outlook(observed: [GlyphID], expectedLength: Int?) -> SequenceOutlook
}

extension PlayerInputValidator: PlayerInputValidating {
    public init(table: GlyphTable, sessionID: CaptureSessionID) {
        self.init(table: table, sessionID: sessionID, policy: Policy())
    }
}

extension SequencePredictor: SequencePredicting {
    public func outlook(observed: [GlyphID], expectedLength: Int?) -> SequenceOutlook {
        outlook(observed: observed, expectedLength: expectedLength, displayCandidateLimit: 8)
    }
}

/// Public factories for the values the C++ arm builds from the core's C
/// structs. The memberwise initializers are internal to this module; factories
/// rather than public initializers, which would be ambiguous with them here.
extension InputCheckSample {
    public static func bridged(time: Double, edges: Set<GlyphPath.Edge>,
                               partialEdges: Set<GlyphPath.Edge>) -> InputCheckSample {
        InputCheckSample(time: time, edges: edges, partialEdges: partialEdges)
    }
}

extension InputCheckResult {
    public static func bridged(sessionID: CaptureSessionID, hackID: Int, slotIndex: Int, attemptID: Int,
                               expectedGlyph: GlyphID, verdict: InputCheckVerdict,
                               reason: InputCheckUnavailableReason?, sourceTime: Double, startTime: Double?,
                               liftTime: Double?, samples: [InputCheckSample],
                               windowEnd: InputCheckWindowEnd) -> InputCheckResult {
        InputCheckResult(sessionID: sessionID, hackID: hackID, slotIndex: slotIndex, attemptID: attemptID,
                         expectedGlyph: expectedGlyph, verdict: verdict, reason: reason, sourceTime: sourceTime,
                         startTime: startTime, liftTime: liftTime, samples: samples, windowEnd: windowEnd)
    }
}

extension InputCheckEvent {
    public static func bridged(kind: Kind, time: Double, hackID: Int, slotIndex: Int, attemptID: Int,
                               reason: InputCheckUnavailableReason?, result: InputCheckResult?,
                               edgeEvidence: [GlyphEdgeEvidence]) -> InputCheckEvent {
        InputCheckEvent(kind: kind, time: time, hackID: hackID, slotIndex: slotIndex, attemptID: attemptID,
                        reason: reason, result: result, edgeEvidence: edgeEvidence)
    }
}
