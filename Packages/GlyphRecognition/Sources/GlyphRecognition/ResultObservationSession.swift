/// Bounded, one-hack observer shared by live capture and replay. Consumers log
/// the retired value before a new hack replaces it. No presentation mutation.
public struct ResultObservationSession: Sendable {
    public private(set) var tracker: HackResultTracker?
    public private(set) var comparison: ValidatorResultComparison?
    public init() {}
    public var context: ResultReadContext? {
        guard tracker?.result.closedAt == nil else { return nil }
        return tracker?.result.context
    }

    /// Called after PresentationTracker.accept and before validator events.
    /// Returns the retired summary when the next hack takes ownership.
    /// `imageAnalyzed` is false for idle or missing frames, which carry no
    /// pixels and so cannot show the panel leaving or the input ending.
    public mutating func observe(_ evidence: FrameEvidence, presentation: PresentationTracker,
                                 panelCandidate: Bool, imageAnalyzed: Bool = true, commands: HackCommandSummary? = nil) -> HackResult? {
        var retired: HackResult?
        if let current = tracker, current.result.context.hackID != presentation.hackID {
            tracker?.finish(at: evidence.time, reason: "newHack")
            retired = tracker?.result
            tracker = nil; comparison = nil
        }
        if tracker == nil, presentation.state == .input,
           let count = presentation.expectedSlotCount, count > 0 {
            let glyphs = (0..<count).map { index -> String? in
                guard let slot = presentation.slots.first(where: { $0.index == index }),
                      slot.status == .confirmed else { return nil }
                return slot.glyph?.name
            }
            let context = ResultReadContext(sessionID: evidence.sessionID, hackID: presentation.hackID, glyphs: glyphs, commands: commands)
            tracker = HackResultTracker(context: context)
            comparison = ValidatorResultComparison(context: context)
        }
        guard imageAnalyzed else { return retired }
        // Any current input cue suffices. On the phone the timer bar dropped out
        // for two frames while the strip still showed the same highlight;
        // gating on the bar alone read that as a frame gap. A fresh input
        // header also contradicts empty-strip exit evidence. Use the same
        // source-time freshness rule as PresentationTracker, not retained state.
        let inputHeader = evidence.header.map {
            $0.phase == .input && $0.sourceTime <= evidence.time
                && evidence.time - $0.sourceTime <= presentation.policy.unknownPhaseGrace
        } ?? false
        let inputVisible = !panelCandidate
            && (inputHeader || evidence.hasInputTimerBar || evidence.slots?.highlightedIndex != nil)
        comparison?.observe(evidence, inputVisible: inputVisible)
        // Empty-strip evidence can start the exit wait only without a current
        // input cue. A known overlay is not empty-strip evidence.
        tracker?.observeFrame(at: evidence.time, inputVisible: inputVisible,
                              exitVisible: evidence.slotRejection == .noMarkers,
                              panelCandidate: panelCandidate)
        return retired
    }

    public mutating func accept(_ evidence: ResultFrameEvidence) { tracker?.accept(evidence) }
    public mutating func accept(_ events: [InputCheckEvent]) { comparison?.accept(events) }
    public mutating func finish(at time: Double, reason: String) { tracker?.finish(at: time, reason: reason) }
}
