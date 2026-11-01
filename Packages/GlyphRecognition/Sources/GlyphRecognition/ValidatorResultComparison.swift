/// Observes the existing validator IDs. This is not a gameplay attempt counter
/// and does not change validator boundaries. A backward highlight invalidates
/// all later submissions until new attempts establish them again.
public struct ValidatorResultComparison: Sendable {
    public enum Status: String, Sendable, Codable { case agreement, disagreement, coverageGap, unknownAssociation, unknownGameOutcome }
    public struct Entry: Sendable {
        public let slotIndex: Int
        public let attemptID: Int?
        public let validatorVerdict: InputCheckVerdict?
        public let gameOutcome: GameSlotOutcome
        public let status: Status
        /// From the first frame with new ink to the frame that proved the lift,
        /// for the attempt the game judged. Nil without a proven start or lift,
        /// which includes every final slot.
        public var drawSeconds: Double? = nil
    }
    public let context: ResultReadContext
    public private(set) var supersededAttemptIDs: Set<Int> = []
    private var attempts: [Int: Int] = [:]
    private var checks: [Int: InputCheckResult] = [:]
    /// The validator's start time is the last clear frame; drawing time
    /// starts at the frame after it, where the attempt began.
    private var firstInk: [Int: Double] = [:]
    private var highlight: Int?
    private var candidate: Int?
    private var candidateCount = 0
    private var lastTime: Double?
    public init(context: ResultReadContext) { self.context = context }

    public mutating func observe(_ evidence: FrameEvidence, inputVisible: Bool) {
        guard evidence.sessionID == context.sessionID, inputVisible else { return }
        guard lastTime == nil || evidence.time > lastTime! else { return }
        let gap = lastTime.map { evidence.time - $0 > 0.102 } ?? false
        lastTime = evidence.time
        guard !gap, let strip = evidence.slots, strip.slotCount == context.glyphs.count,
              let index = strip.highlightedIndex else {
            invalidate(from: 0); highlight = nil; candidate = nil; candidateCount = 0
            return
        }
        if candidate == index { candidateCount += 1 } else { candidate = index; candidateCount = 1 }
        guard candidateCount >= 2, highlight != index else { return }
        if let old = highlight {
            if index < old { invalidate(from: index) }
            else if index > old + 1 { invalidate(from: old) }
        }
        highlight = index
    }

    public mutating func accept(_ events: [InputCheckEvent]) {
        for event in events where event.hackID == context.hackID {
            guard context.glyphs.indices.contains(event.slotIndex) else { continue }
            if event.kind == .started {
                invalidate(from: event.slotIndex)
                attempts[event.slotIndex] = event.attemptID
                if event.reason == nil { firstInk[event.slotIndex] = event.time }
            }
            if let result = event.result, result.sessionID == context.sessionID,
               attempts[event.slotIndex] == event.attemptID,
               context.glyphs[event.slotIndex] == result.expectedGlyph.name {
                checks[event.slotIndex] = result
            }
        }
    }

    private mutating func invalidate(from index: Int) {
        for slot in Array(attempts.keys) where slot >= index {
            if let id = attempts.removeValue(forKey: slot) { supersededAttemptIDs.insert(id) }
            checks.removeValue(forKey: slot)
            firstInk.removeValue(forKey: slot)
        }
    }

    public func compare(_ result: HackResult) -> [Entry] {
        guard result.context == context else { return [] }
        return result.outcomes.indices.map { index in
            let outcome = result.outcomes[index]
            let check = checks[index]
            let status: Status
            if outcome == .unknown { status = .unknownGameOutcome }
            else if attempts[index] == nil { status = .unknownAssociation }
            else if check == nil || check?.verdict == .unavailable { status = .coverageGap }
            else {
                let agrees = (outcome == .accepted && check?.verdict == .matched)
                    || (outcome == .rejected && check?.verdict == .differs)
                status = agrees ? .agreement : .disagreement
            }
            var drawSeconds: Double?
            if let check, check.startTime != nil, let start = firstInk[index], let lift = check.liftTime,
               lift > start, lift - start < 30 {
                drawSeconds = lift - start
            }
            return Entry(slotIndex: index, attemptID: attempts[index], validatorVerdict: check?.verdict,
                         gameOutcome: outcome, status: status, drawSeconds: drawSeconds)
        }
    }
}
