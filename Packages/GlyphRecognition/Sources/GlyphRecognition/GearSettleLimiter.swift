/// Whether a gear read due now may be answered with the current panel's
/// settled reading instead (the `gearSettle` cut). A visible panel is read
/// every `GameHeaderReader.gearInterval`, each read several accurate Vision
/// passes, for as long as it shows. Once `GearDropTracker` calls the panel
/// settled, every row it showed confirmed by two agreeing reads and none left
/// unparsed, a further read of the same pixels can only repeat what it has.
/// While the panel's pixels and bounds stay still against the frame of the
/// read that settled it, the lane issues that read's evidence again at the
/// due frame's time, so the tracker sees reads at the same frames, with the
/// same rows, and its departure, hold and close times are unchanged.
///
/// Clock-free, like `PortalReadLimiter`: the caller tells it each real read
/// with whether it left the panel settled, and each analysed frame's look.
public struct GearSettleLimiter: Sendable, Equatable {
    /// A cell is about 8 by 10 pixels of a 1080-wide frame's panel: a
    /// finer grid than the header's, as a panel's rows fill its height.
    public static let columns = 120
    public static let rows = 48
    /// Mean grey-level difference from the settling read's frame at or under
    /// which the panel is still. Measured on the frames of seven
    /// recordings with gear (bounds within 0.003 of each other): pairs that
    /// read the same differ by at most 1.17 at the 90th percentile, more
    /// only under pickup sparks; a panel replaced in the same place differs
    /// by at least 5.29 (English, where OCR is stable enough to tell).
    public static let tolerance = 2.0
    /// The new-panel check's own threshold (`GameTextSchedule.newPanelShift`):
    /// bounds that moved further are another panel to the lane too.
    public static let boundsTolerance = GameTextSchedule.newPanelShift
    /// A settled panel is read for real at least this often. A reissued
    /// reading then never stands for a read more than a second old, well
    /// within the 1.2 s the tracker lets pass between two agreeing reads of
    /// a row (`GearDropTracker.Policy.maximumReadingGap`), and the header
    /// still skip's age limit.
    public static let refreshAfter = 1.0

    private var core = PanelSettleLimiter<GearDropFrameEvidence>(
        tolerance: tolerance, boundsTolerance: boundsTolerance, refreshAfter: refreshAfter)

    public init() {}

    /// The rectangle the gear reader reads for a panel at `bounds`, in a
    /// frame `width` by `height`: its rows, 0.035 to 0.965 of the width.
    public static func region(_ bounds: GearDropPanelBounds, width: Int, height: Int) -> PanelRegion? {
        PanelRegion(left: 0.035, right: 0.965, top: bounds.top, bottom: bounds.bottom, width: width, height: height)
    }

    public var isSettled: Bool { core.isSettled }
    /// Where each frame's signature is built while settled: the settling
    /// read's panel, not the frame's own, so the grids line up.
    public var region: PanelRegion? { core.region }

    /// A real read, accepted by the tracker. `settled` is the tracker's
    /// `currentPanelSettled` after it; `signature` is the read's own frame's,
    /// over `region`, the rectangle of the panel at `bounds` there.
    public mutating func accept(_ read: GearDropFrameEvidence, settled: Bool, signature: StillSignature?,
                                region: PanelRegion, bounds: GearDropPanelBounds) {
        guard settled, read.stage == .portal || read.stage == .bonus else { core.reset(); return }
        core.settle(read, signature: signature, region: region, bounds: bounds)
    }

    /// An analysed frame. `settled` is the tracker's current panel state,
    /// which a hold, a close or a contradicting read ends; `bounds` the
    /// frame's panel, nil when none shows. The reading to issue for a gear
    /// read due at this frame, or nil to read it.
    public mutating func look(at time: Double, settled: Bool, signature: StillSignature?,
                              bounds: GearDropPanelBounds?) -> GearDropFrameEvidence? {
        guard settled, bounds != nil else { core.reset(); return nil }
        return core.look(at: time, signature: signature, bounds: bounds)
    }

    /// Continuity lost, or the session's gear invalidated.
    public mutating func reset() { core.reset() }
}
