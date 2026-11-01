/// Reads conclusions independently of PresentationTracker and the input
/// validator. Old/cached OCR never votes twice and never crosses hack identity.
public struct HackResultTracker: Sendable {
    public struct Policy: Sendable {
        /// Two agreeing reads this far apart also reject a value that trails
        /// the stage name by less than this: the later read would disagree.
        /// The recordings show no such lag at 20 Hz.
        public var minimumSpan = 0.1
        public var maximumReadingGap = 0.3
        public var panelExitSpan = 0.2
        /// Counted from observed exit evidence, never from input evidence
        /// merely going out of sight behind a window or banner.
        public var resultWait = 5.0
        public init() {}
    }

    private struct Run<Value: Equatable & Sendable>: Sendable {
        var value: Value?
        var first = 0.0
        var last = 0.0
        var count = 0

        mutating func accept(_ next: Value?, at time: Double, policy: Policy) -> Bool {
            guard let next else { self = Self(); return false }
            if value != next || time - last > policy.maximumReadingGap + 1e-9 {
                value = next; first = time; count = 0
            }
            last = time; count += 1
            return count >= 2 && time - first + 1e-9 >= policy.minimumSpan
        }
    }

    public let policy: Policy
    public private(set) var result: HackResult
    public private(set) var revision = 0
    private var previousTime = -Double.infinity
    private var stage = Run<Int>()
    private var hacking = Run<Int>()
    private var speed = Run<Int>()
    private var slots: [Run<ResultSlotAppearance>]
    private var conflictedSlots: Set<Int> = []
    private var absentSince: Double?
    private var exitSince: Double?

    public init(context: ResultReadContext, policy: Policy = Policy()) {
        self.policy = policy
        result = HackResult(context: context, outcomes: Array(repeating: .unknown, count: context.glyphs.count),
                            outcomeTimes: Array(repeating: nil, count: context.glyphs.count))
        slots = Array(repeating: Run(), count: context.glyphs.count)
    }

    @discardableResult
    public mutating func accept(_ evidence: ResultFrameEvidence) -> Bool {
        guard result.closedAt == nil, evidence.context == result.context,
              evidence.sourceTime.isFinite, evidence.sourceTime > previousTime else { return false }
        let before = result
        let time = evidence.sourceTime
        previousTime = time
        guard evidence.panelPresent else {
            stage = Run(); hacking = Run(); speed = Run()
            slots = Array(repeating: Run(), count: slots.count)
            return false
        }
        result.firstPanelTime = result.firstPanelTime ?? time
        result.lastPanelTime = time
        absentSince = nil
        if let value = evidence.hackingBonus { result.observedHackingBonus = value }
        if let value = evidence.speedBonus { result.observedSpeedBonus = value }

        for index in slots.indices where !conflictedSlots.contains(index) {
            let appearance = index < evidence.appearances.count ? evidence.appearances[index] : .unreadable
            let known: ResultSlotAppearance? = appearance == .unreadable ? nil : appearance
            if slots[index].accept(known, at: time, policy: policy), let known {
                let outcome: GameSlotOutcome = known == .gold ? .accepted : .rejected
                // Contradiction is uncertainty, not permission to overwrite a result.
                if result.outcomes[index] != .unknown && result.outcomes[index] != outcome {
                    conflictedSlots.insert(index)
                    result.outcomes[index] = .unknown
                    result.outcomeTimes[index] = nil
                } else {
                    result.outcomes[index] = outcome
                    result.outcomeTimes[index] = result.outcomeTimes[index] ?? time
                }
            }
        }

        let finalIndex = result.context.glyphs.count - 1
        let namedStage = evidence.stageIndex.flatMap { (0...max(0, finalIndex)).contains($0) ? $0 : nil }
        // A lit last contour, gold or magenta, reveals the final stage as its
        // name does; the short name is often unread through the sparks. A name
        // for an earlier slot contradicts it, so neither counts.
        let finalRevealed = evidence.appearances.indices.contains(finalIndex)
            && evidence.appearances[finalIndex] != .unreadable
        let validStage = finalRevealed ? (namedStage == nil || namedStage == finalIndex ? finalIndex : nil) : namedStage
        if (stage.value != validStage || time - stage.last > policy.maximumReadingGap + 1e-9),
           result.finalHackingBonus == nil || result.finalSpeedBonus == nil {
            result.finalStageTime = nil
        }
        let finalStageConfirmed = stage.accept(validStage, at: time, policy: policy) && validStage == finalIndex
        if finalStageConfirmed { result.finalStageTime = result.finalStageTime ?? stage.first }
        // Finality never depends on illumination or a bonus increase. Every
        // vote is a current final-stage read, not a name cached from earlier.
        if validStage == finalIndex {
            if let value = evidence.hackingBonus, let final = result.finalHackingBonus, value != final {
                result.finalHackingBonus = nil
            }
            if let value = evidence.speedBonus, let final = result.finalSpeedBonus, value != final {
                result.finalSpeedBonus = nil
            }
            let hackingAgrees = hacking.accept(evidence.hackingBonus, at: time, policy: policy)
            let speedAgrees = speed.accept(evidence.speedBonus, at: time, policy: policy)
            if finalStageConfirmed, hackingAgrees { result.finalHackingBonus = evidence.hackingBonus }
            if finalStageConfirmed, speedAgrees { result.finalSpeedBonus = evidence.speedBonus }
        } else { hacking = Run(); speed = Run() }
        updateState()
        if result != before { revision += 1; return true }
        return false
    }

    /// Cheap geometry drives departure/timeout even when no OCR request fits.
    /// A candidate alone cannot establish a panel, a value, or an outcome.
    /// Call only for frames whose pixels were analyzed: an idle or missing
    /// frame shows neither the panel nor its absence.
    ///
    /// The wait starts at positive exit evidence. Input evidence merely going
    /// out of sight, behind a window or banner, leaves the hack open until
    /// exit evidence, a new hack, or capture stop.
    public mutating func observeFrame(at time: Double, inputVisible: Bool, exitVisible: Bool,
                                      panelCandidate: Bool) {
        guard time.isFinite, result.closedAt == nil else { return }
        if inputVisible, result.firstPanelTime == nil {
            result.inputStartedAt = result.inputStartedAt ?? time
            result.inputEndedAt = time
        }
        if inputVisible { exitSince = nil }
        else if exitVisible || panelCandidate { exitSince = exitSince ?? time }
        if panelCandidate { absentSince = nil }
        else if let lastPanel = result.lastPanelTime, time > lastPanel {
            absentSince = absentSince ?? time
            if time - absentSince! >= policy.panelExitSpan { finish(at: time, reason: "panelLeft") }
        }
        if let exitSince, time - max(exitSince, result.lastPanelTime ?? exitSince) > policy.resultWait {
            finish(at: time, reason: "resultTimeout")
        }
    }

    public mutating func finish(at time: Double, reason: String) {
        guard result.closedAt == nil else { return }
        result.closedAt = time; result.closeReason = reason
        updateState()
        revision += 1
    }

    private mutating func updateState() {
        if result.firstPanelTime == nil {
            result.state = result.closedAt == nil ? .awaiting : .notObserved
        } else {
            result.state = result.finalHackingBonus != nil && result.finalSpeedBonus != nil
                && !result.outcomes.contains(.unknown) ? .complete : .partial
        }
    }
}
