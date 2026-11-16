/// Whether the portal screen on view still needs reading (the `portalSettle`
/// cut). A read costs two accurate Vision requests and holds the text lane,
/// and without this a screen is read for as long as it shows. Once one read
/// already decides the level, or two reads in a row with a faded-in badge
/// say the same, further reads of that screen can only repeat it or swap in
/// a different misread.
/// A screen held longer still gets one read now and then, so the observer's
/// reading stays young enough to attach to the hack that follows.
///
/// It sees no pixels and keeps no clock: the caller tells it each analysed
/// frame's portal check, each finished read and each reset, and asks before
/// offering a read. Reads already taken are unaffected; the observer accepts
/// them as before.
public struct PortalReadLimiter: Sendable, Equatable {
    /// One portal screen: from its first candidate frame until the candidate
    /// has been gone for longer than the observer's same-screen window, or
    /// shows another faction.
    private struct Screen: Sendable, Equatable {
        let faction: PortalFaction
        let startedAt: Double
        var lastSeenAt: Double
        var lastRead: PortalScreenEvidence?
        var settled = false
    }

    /// Absence longer than this ends a screen: the observer's window, so a
    /// screen the limiter calls new is one the observer starts afresh too.
    public let sameScreen: Double
    /// A settled screen's last read older than this is read again. The
    /// observer attaches a read to a hack only within its attach window;
    /// half of it leaves the other half for the new read and for the command
    /// screen before the hack's Glyphs, which lasted up to about 4 s.
    public let refreshAfter: Double
    private var screen: Screen?

    public init(policy: PortalLevelObserver.Policy = PortalLevelObserver.Policy()) {
        sameScreen = policy.sameScreen
        refreshAfter = policy.attachWindow / 2
    }

    /// The current screen has been read enough.
    public var isSettled: Bool { screen?.settled == true }

    /// An analysed frame the portal check found a screen on.
    public mutating func candidate(at time: Double, faction: PortalFaction) {
        guard time.isFinite else { screen = nil; return }
        if var current = screen, current.faction == faction, time >= current.lastSeenAt,
           time - current.lastSeenAt <= sameScreen {
            current.lastSeenAt = time
            screen = current
        } else {
            screen = Screen(faction: faction, startedAt: time, lastSeenAt: time)
        }
    }

    /// An analysed frame the portal check found no screen on. A clock that
    /// went back, or a time that is not finite, ends the screen: a read too
    /// many is cheaper than a screen wrongly called settled.
    public mutating func absent(at time: Double) {
        guard let current = screen else { return }
        if !time.isFinite || time < current.lastSeenAt || time - current.lastSeenAt > sameScreen { screen = nil }
    }

    /// A finished read. Only a read of the current screen counts: taken on
    /// or after its first frame, in time order, and of its faction when the
    /// read names one. A settled screen's refreshing read starts its reading
    /// afresh, as it starts a new screen for the observer.
    public mutating func accept(_ evidence: PortalScreenEvidence) {
        guard var current = screen, evidence.sourceTime.isFinite, evidence.sourceTime >= current.startedAt,
              current.lastRead.map({ evidence.sourceTime >= $0.sourceTime }) ?? true,
              evidence.faction.map({ $0 == current.faction }) ?? true else { return }
        if current.settled, let last = current.lastRead, evidence.sourceTime - last.sourceTime > refreshAfter {
            current.settled = false
            current.lastRead = nil
        }
        if Self.decidesLevel(evidence) || current.lastRead.map({ Self.agree($0, evidence) }) == true {
            current.settled = true
        }
        current.lastRead = evidence
        screen = current
    }

    /// Continuity lost, a hack started (its screen is claimed) or a new
    /// session: whatever shows next is read afresh.
    public mutating func reset() {
        screen = nil
    }

    /// Whether a read offered at `time` is wanted. Nothing settled, nothing
    /// withheld: without a current screen the answer is always yes.
    public func wantsRead(at time: Double) -> Bool {
        guard let current = screen, current.settled, let last = current.lastRead, time.isFinite,
              time >= current.lastSeenAt, time - current.lastSeenAt <= sameScreen else { return true }
        return time - last.sourceTime > refreshAfter
    }

    /// All eight labels parsed, none unread, and a badge that names one
    /// level which the ring confirms: the estimate is exact and of high
    /// confidence from this read alone, with no Glyph count needed.
    static func decidesLevel(_ read: PortalScreenEvidence) -> Bool {
        guard read.resonators.count == 8, read.unreadSlots == 0, let hue = read.badgeHue,
              PortalLevelRules.levels(forBadgeHue: hue)?.count == 1,
              let estimate = PortalLevelRules.estimate(resonators: read.resonators, unreadSlots: read.unreadSlots,
                                                       badgeHue: hue, glyphCount: nil) else { return false }
        return estimate.confidence == .high && !estimate.conflict
    }

    /// Two reads of one screen in a row say the same: the faction, at least
    /// one level and the same levels in any order, the unread count, and a
    /// badge on both that names one level, their hues within the tolerance a
    /// calibrated hue is matched with. The labels and the badge fade in
    /// together, so two reads taken while they do can agree on what is
    /// still changing: two without a badge agreed on four labels of a screen
    /// that showed six a second later, and two with an L8 badge still at
    /// 236° (it reached 254° half a second later) agreed on two labels and
    /// cost the hack its badge level.
    static func agree(_ earlier: PortalScreenEvidence, _ later: PortalScreenEvidence) -> Bool {
        guard let first = earlier.badgeHue, let second = later.badgeHue, !later.resonators.isEmpty,
              PortalLevelRules.levels(forBadgeHue: first)?.count == 1,
              PortalLevelRules.levels(forBadgeHue: second)?.count == 1,
              earlier.faction == later.faction, earlier.resonators.sorted() == later.resonators.sorted(),
              earlier.unreadSlots == later.unreadSlots else { return false }
        return PortalLevelRules.hueDistance(first, second) <= PortalLevelRules.calibrationTolerance
    }
}
