/// Keeps the hacks waiting for drops separately from visual groups. Groups
/// arrive oldest first, so each goes to the oldest waiting hack. Ordinary
/// hacks queue too but are invisible here, so that match is recorded as
/// ordered, never as proven.
public struct GearDropObservationSession: Sendable {
    public struct Policy: Sendable {
        /// Restarted by a later hack's input end and by the Hacking Bonus
        /// page or a drop panel staying on screen, as while offline.
        public var inactivityLimit = 30.0
        public var absoluteLimit = 120.0
        public var maximumWaiting = 16
        /// How soon after a group that ended on its Bonus panel an empty
        /// Bonus-only group counts as that panel found again. An untouched
        /// panel shows for about 2 s; pickup sparks hid a tester's Bonus
        /// panel from the detector for 1.05 s while it stayed on screen.
        /// The tracker holds a group whose Bonus rows are unconfirmed, so
        /// such a panel joins it; this covers a panel that left confirmed.
        public var repeatedBonusWindow = 2.0
        public init() {}
    }
    public struct Wait: Sendable, Equatable, Codable {
        public let hackID: Int
        public let startedAt: Double
        public var lastProgress: Double
        public var finalBonus: Int?
    }
    public struct Event: Sendable, Equatable, Codable {
        public let time: Double
        public let hackID: Int?
        public let reason: String
    }
    public let policy: Policy
    public private(set) var waiting: [Wait] = []
    public private(set) var events: [Event] = []
    private var seen: Set<Int> = []
    private var lastInputHack: Int?
    private var lastFrameTime: Double?
    /// After a wait expired or continuity was lost, a late group could belong
    /// to a hack no longer in the queue, so order cannot name its owner.
    /// Groups stay unattached until the queue has emptied and a quiet period
    /// has passed since the last such event; in normal play the queue empties
    /// after every hack's drops.
    private var associationUncertain = false
    private var uncertainSince = -Double.infinity
    /// When the last group closed, if it ended on a Bonus panel.
    private var lastBonusEnd = -Double.infinity
    public var isAssociationUncertain: Bool { associationUncertain }

    public init(policy: Policy = Policy()) { self.policy = policy }

    /// Call before draining OCR, so a late completion cannot use the old queue.
    /// `continuityLost` comes from the caller, who can tell a stalled capture
    /// from a still screen: an unchanged screen repeats its timestamp and
    /// yields no new frames for a while, which is not a break.
    @discardableResult
    public mutating func prepareFrame(at time: Double, continuityLost: Bool) -> Bool {
        guard time.isFinite else { return false }
        let lost = continuityLost || (lastFrameTime.map { time < $0 } ?? false)
        lastFrameTime = max(lastFrameTime ?? time, time)
        if lost { invalidate(at: time, reason: "frameGap") }
        return lost
    }

    /// A new input does not retire previous gear waits. Identity comes only
    /// from the presentation tracker; gear never changes that tracker's state.
    /// `gameProgressVisible` is the cheap Hacking Bonus page or drop-panel
    /// geometry: the game is still working through its hacks.
    public mutating func observe(at time: Double, hackID: Int, inputVisible: Bool,
                                 gameProgressVisible: Bool = false, inputPhase: TrackingState = .input) {
        guard time.isFinite else { return }
        if let lastFrameTime, time < lastFrameTime { return }
        lastFrameTime = time
        if inputVisible, inputPhase == .input, hackID > 0 { lastInputHack = hackID }
        else if let ended = lastInputHack {
            enqueue(hackID: ended, at: time)
            lastInputHack = nil
        }
        if gameProgressVisible { for index in waiting.indices { waiting[index].lastProgress = time } }
        expire(at: time)
        settleUncertainty(at: time)
    }

    public mutating func enqueue(hackID: Int, at time: Double) {
        guard time.isFinite, hackID > 0, seen.insert(hackID).inserted else { return }
        for index in waiting.indices { waiting[index].lastProgress = time }
        waiting.append(Wait(hackID: hackID, startedAt: time, lastProgress: time))
        events.append(Event(time: time, hackID: hackID, reason: "waiting"))
        if waiting.count > policy.maximumWaiting { invalidate(at: time, reason: "queueLimit") }
    }

    public mutating func accept(_ result: HackResult) {
        if let index = waiting.firstIndex(where: { $0.hackID == result.context.hackID }) {
            waiting[index].finalBonus = result.finalHackingBonus
        }
    }

    public mutating func close(_ group: GearDropSummary) -> GearDropSummary {
        var group = group
        let time = group.closedAt
        expire(at: time)
        settleUncertainty(at: time)
        group.hackID = nil
        let previousBonusEnd = lastBonusEnd
        lastBonusEnd = group.panels.last?.stage == .bonus ? time : -.infinity
        // A drop starts with its portal panel. A Bonus panel with no row read,
        // first seen soon after the last group ended on a Bonus panel, is most
        // likely that panel again, lost for a moment under pickup sparks: it
        // must not use up the next hack's wait. A group with any row read, or
        // with a portal panel, is matched as before.
        if group.panels.count == 1, let panel = group.panels.first, panel.stage == .bonus,
           panel.entries.isEmpty, group.startedAt >= previousBonusEnd,
           group.startedAt - previousBonusEnd <= policy.repeatedBonusWindow {
            group.association = .repeatedBonus
            return group
        }
        guard let oldest = waiting.first else {
            group.association = associationUncertain ? .uncertainContinuity : .noWaitingHack
            return group
        }
        if !group.panels.contains(where: { $0.stage == .bonus }),
           let bonus = oldest.finalBonus, bonus > 0 {
            // Bonus items were promised, so this is most likely an ordinary
            // hack's group; the Glyph hack keeps waiting for its own.
            group.association = .bonusExpected
            return group
        }
        // While uncertain the group still uses up the oldest wait, unattached:
        // otherwise that wait would expire later and start the doubt again.
        waiting.removeFirst()
        if associationUncertain {
            group.association = .uncertainContinuity
            events.append(Event(time: time, hackID: oldest.hackID, reason: "uncertainContinuity"))
        } else {
            group.association = group.panels.contains(where: { $0.stage == .bonus }) ? .ordered : .orderedWithoutBonus
            group.hackID = oldest.hackID
            events.append(Event(time: time, hackID: oldest.hackID, reason: group.association.rawValue))
        }
        settleUncertainty(at: time)
        return group
    }

    public mutating func expire(at time: Double) {
        let expired = waiting.filter {
            time - $0.lastProgress > policy.inactivityLimit || time - $0.startedAt > policy.absoluteLimit
        }
        guard !expired.isEmpty else { return }
        associationUncertain = true; uncertainSince = time
        for wait in expired { events.append(Event(time: time, hackID: wait.hackID, reason: "waitTimeout")) }
        let ids = Set(expired.map(\.hackID))
        waiting.removeAll { ids.contains($0.hackID) }
    }

    public mutating func invalidate(at time: Double, reason: String) {
        // With nobody waiting, no group can be given to the wrong hack.
        if !waiting.isEmpty { associationUncertain = true; uncertainSince = time }
        for wait in waiting { events.append(Event(time: time, hackID: wait.hackID, reason: reason)) }
        waiting = []; lastInputHack = nil
    }

    private mutating func settleUncertainty(at time: Double) {
        guard associationUncertain, waiting.isEmpty, time - uncertainSince >= policy.inactivityLimit else { return }
        associationUncertain = false
        events.append(Event(time: time, hackID: nil, reason: "orderRestored"))
    }
}
