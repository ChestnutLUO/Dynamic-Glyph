/// Whether a result read due now may be answered with the hack's settled
/// result reading instead (the `resultSettle` cut). A result panel with a
/// result context is read on every look the lane allows, an accurate Vision
/// pass each (two when a bonus is misread), until it leaves. Once `HackResultTracker` calls the result
/// complete, every slot's outcome and both bonuses final, and the last two
/// reads agreed, a further read of the same pixels can only repeat it. While
/// the panel's pixels stay still against the frame of the settling read, the
/// lane issues that read again at the due frame's time, so the tracker's
/// last panel time, its exit wait and its close time move as with reads.
///
/// Clock-free, like `PortalReadLimiter`: the caller tells it each real read
/// with whether it left the result complete, and each analysed frame's look.
public struct ResultSettleLimiter: Sendable, Equatable {
    public static let columns = 120
    public static let rows = 64
    /// Mean grey-level difference from the settling read's frame at or under
    /// which the panel is still. The slot hexagons glow on a finished panel:
    /// measured on four recordings with results, frames of one
    /// panel reading its final result differ by up to 4.67, while a frame
    /// still counting up differs from them by at least 5.95, and another
    /// hack's panel by at least 6.41. Nothing on a complete panel changes
    /// until it leaves, which differs by far more.
    public static let tolerance = 5.0
    /// A settled result is read for real at least this often, as a settled
    /// gear panel is (`GearSettleLimiter.refreshAfter`).
    public static let refreshAfter = 1.0

    private var core = PanelSettleLimiter<ResultFrameEvidence>(
        tolerance: tolerance, boundsTolerance: 0, refreshAfter: refreshAfter)
    /// The last real read, for the agreement of two in a row.
    private var previous: ResultFrameEvidence?

    public init() {}

    /// The rectangle the result reader reads in a frame `width` by `height`:
    /// the slot hexagons from 0.11 of the height, the stage name and bonuses
    /// down to 0.62, the full width.
    public static func region(width: Int, height: Int) -> PanelRegion? {
        PanelRegion(left: 0, right: 1, top: 0.11, bottom: 0.62, width: width, height: height)
    }

    public var isSettled: Bool { core.isSettled }
    /// Where each frame's signature is built while settled.
    public var region: PanelRegion? { core.region }

    /// A real read of the current context, accepted by the tracker.
    /// `complete` is the tracker's state after it (`HackResult.State
    /// .complete`: every outcome read, both bonuses final); `signature` is the
    /// read's own frame's, over `region`.
    public mutating func accept(_ read: ResultFrameEvidence, complete: Bool, signature: StillSignature?,
                                region: PanelRegion) {
        let agrees = previous.map { Self.agree($0, read) } ?? false
        previous = read
        guard complete, agrees else { core.reset(); return }
        core.settle(read, signature: signature, region: region, bounds: nil)
    }

    /// An analysed frame. `context` is the result session's current one and
    /// `panelCandidate` whether the frame shows a result panel. The reading
    /// to issue for a result read due at this frame, or nil to read it.
    public mutating func look(at time: Double, context: ResultReadContext?, panelCandidate: Bool,
                              signature: StillSignature?) -> ResultFrameEvidence? {
        guard panelCandidate, let context, previous?.context == context else { reset(); return nil }
        return core.look(at: time, signature: signature, bounds: nil)
    }

    /// Continuity lost, a new hack or session.
    public mutating func reset() {
        core.reset()
        previous = nil
    }

    /// Two reads say the same: the same context, a panel on both, the same
    /// stage, bonuses, slot appearances and label language. The recognised
    /// lines may differ in confidence and box; what the tracker takes from a
    /// read may not.
    static func agree(_ earlier: ResultFrameEvidence, _ later: ResultFrameEvidence) -> Bool {
        earlier.context == later.context && earlier.panelPresent && later.panelPresent
            && earlier.stageIndex == later.stageIndex && earlier.hackingBonus == later.hackingBonus
            && earlier.speedBonus == later.speedBonus && earlier.appearances == later.appearances
            && earlier.labelLanguage == later.labelLanguage
    }
}

extension ResultFrameEvidence: SettledPanelReading {
    public func at(sourceTime time: Double) -> ResultFrameEvidence {
        ResultFrameEvidence(context: context, sourceTime: time, panelPresent: panelPresent, stageIndex: stageIndex,
                            hackingBonus: hackingBonus, speedBonus: speedBonus, appearances: appearances,
                            lines: lines, labelLanguage: labelLanguage)
    }
}
