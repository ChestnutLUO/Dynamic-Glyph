/// A panel read whose reading a settle limiter can issue again at a later
/// frame's time, in place of a read of that frame.
public protocol SettledPanelReading: Sendable, Equatable {
    var sourceTime: Double { get }
    /// The same reading, as if read from the frame at `time`.
    func at(sourceTime time: Double) -> Self
}

extension GearDropFrameEvidence: SettledPanelReading {
    public func at(sourceTime time: Double) -> GearDropFrameEvidence {
        GearDropFrameEvidence(sourceTime: time, stage: stage, bounds: bounds, entries: entries,
                              unreadableRows: unreadableRows, effects: effects, titleLanguage: titleLanguage)
    }
}

/// A rectangle of a frame in pixels, top-left origin, where a settle
/// limiter's still signatures are laid.
public struct PanelRegion: Sendable, Equatable {
    public let left: Int
    public let top: Int
    public let width: Int
    public let height: Int

    public init(left: Int, top: Int, width: Int, height: Int) {
        self.left = left; self.top = top; self.width = width; self.height = height
    }

    /// The pixels inside the fractions `left..<right` and `top..<bottom` of a
    /// frame `width` by `height`, edges rounded outwards and clamped to the
    /// frame; nil when nothing is left of it.
    public init?(left: Double, right: Double, top: Double, bottom: Double, width: Int, height: Int) {
        guard left.isFinite, right.isFinite, top.isFinite, bottom.isFinite, width > 0, height > 0 else { return nil }
        let x0 = max(0, Int((left * Double(width)).rounded(.down)))
        let x1 = min(width, Int((right * Double(width)).rounded(.up)))
        let y0 = max(0, Int((top * Double(height)).rounded(.down)))
        let y1 = min(height, Int((bottom * Double(height)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        self.init(left: x0, top: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// The core of the panel settle cuts (`gearSettle`, `resultSettle`): once a
/// panel's reading has settled, a read due at a later frame is answered with
/// that reading, issued again at the frame's own time, for as long as the
/// panel's pixels stay still against the frame of the read that settled it.
/// The reads stand in at the frames real reads would have been taken, so
/// what consumes them sees the same times and, while the panel is unchanged,
/// the same values.
///
/// It sees no pixels and keeps no clock: the caller builds each frame's
/// signature over `region`, tells it each settling read, each frame's look
/// and each reset, and issues what a look returns. Anything uncertain reads:
/// a frame without a signature, a change beyond the tolerance, panel bounds
/// that moved, a time that is not finite or went back, and every look once
/// the settling read is `refreshAfter` old. All but the last end the anchor,
/// so the panel is read until it settles again.
public struct PanelSettleLimiter<Reading: SettledPanelReading>: Sendable, Equatable {
    private struct Anchor: Sendable, Equatable {
        let reading: Reading
        let signature: StillSignature
        let region: PanelRegion
        let bounds: GearDropPanelBounds?
    }

    /// Mean grey-level difference from the anchor at or under which a frame
    /// is still.
    public let tolerance: Double
    /// How far either edge of the panel's bounds, as a fraction of the
    /// frame's height, may lie from the anchor's.
    public let boundsTolerance: Double
    /// A settling read older than this is never issued again: the next due
    /// read is a real one, which settles again if nothing changed.
    public let refreshAfter: Double
    private var anchor: Anchor?
    private var lastLook = -Double.infinity

    public init(tolerance: Double, boundsTolerance: Double, refreshAfter: Double) {
        self.tolerance = tolerance
        self.boundsTolerance = boundsTolerance
        self.refreshAfter = refreshAfter
    }

    /// A panel's reading has settled, and a read is anchored.
    public var isSettled: Bool { anchor != nil }
    /// Where each frame's signature is to be built while settled.
    public var region: PanelRegion? { anchor?.region }

    /// A real read that settled its panel: `signature` is its own frame's,
    /// over `region`, with the panel's `bounds` there when it has any. A read
    /// without a signature, or out of time, anchors nothing.
    public mutating func settle(_ reading: Reading, signature: StillSignature?, region: PanelRegion,
                                bounds: GearDropPanelBounds?) {
        guard let signature, reading.sourceTime.isFinite else { reset(); return }
        anchor = Anchor(reading: reading, signature: signature, region: region, bounds: bounds)
        lastLook = reading.sourceTime
    }

    /// The panel left, changed or stopped being settled, continuity was
    /// lost or a new session began: read it again.
    public mutating func reset() {
        anchor = nil
        lastLook = -.infinity
    }

    /// An analysed frame at `time`: its `signature` over `region`, nil when
    /// none could be built, and its panel `bounds`. Returns the settled
    /// reading at `time` when this frame is still against it and the read is
    /// young enough; nil otherwise, ending the anchor unless only its age
    /// stood in the way.
    public mutating func look(at time: Double, signature: StillSignature?,
                              bounds: GearDropPanelBounds?) -> Reading? {
        guard let current = anchor else { return nil }
        guard time.isFinite, time >= current.reading.sourceTime, time >= lastLook, let signature,
              signature.isStill(comparedWith: current.signature, tolerance: tolerance),
              boundsAgree(current.bounds, bounds) else {
            reset()
            return nil
        }
        lastLook = time
        guard time - current.reading.sourceTime <= refreshAfter else { return nil }
        return current.reading.at(sourceTime: time)
    }

    private func boundsAgree(_ anchored: GearDropPanelBounds?, _ current: GearDropPanelBounds?) -> Bool {
        guard let anchored else { return true }
        guard let current, current.top.isFinite, current.bottom.isFinite else { return false }
        return abs(current.top - anchored.top) <= boundsTolerance
            && abs(current.bottom - anchored.bottom) <= boundsTolerance
    }
}
