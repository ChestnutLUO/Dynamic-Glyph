/// One visible drop group. Repeated frames replace evidence; they never add
/// quantities. Each entry position is confirmed on its own: one misread row,
/// or a level lost behind the panel's sparkle, never discards the others.
public struct GearDropTracker: Sendable {
    public enum ReadingDisposition: String, Sendable {
        case accepted, invalidTime, outOfOrder, closedInterval, nonPanel
    }
    public private(set) var readingDisposition: ReadingDisposition = .nonPanel
    public struct Policy: Sendable {
        public var minimumSpan = 0.1
        /// The longest wait between two agreeing reads of one row. On a phone
        /// in Glyph assistance a panel read can take 0.5–1 s: a tester's two
        /// identical Bonus reads came 0.91 s apart, and at 0.35 s every row
        /// of both panels was discarded. The gap need not prove the reads saw
        /// the same panel: per-frame geometry closes the group 0.15 s after
        /// the panel leaves, a stage change saves the panel and clears its
        /// rows, and a contradicting read drops the runs it contradicts. It
        /// only bounds how stale a supporting read can be, so 1.2 s leaves
        /// headroom over one slow read and stays well inside `groupLimit`.
        /// Time a held Bonus panel was away (`bonusReturnWindow`) does not
        /// age its reads: they waited unseen, not on screen.
        public var maximumReadingGap = 1.2
        public var departureSpan = 0.15
        /// A Bonus panel that leaves with rows unconfirmed keeps its group
        /// open this long after the departure. Pickup sparks hid a tester's
        /// Bonus panel from the detector for 1.05 s while it stayed on
        /// screen; if a Bonus panel shows again in time, its reads join the
        /// group. Otherwise the group closes as it would have at departure.
        public var bonusReturnWindow = 2.0
        /// A request from this group's source interval may finish after the
        /// panel leaves. Drain it before publishing, but bound a stuck reader.
        public var maximumCompletionWait = 2.0
        public var groupLimit = 5.0
        public init() {}
    }

    /// Agreement for one row and column of the current panel. A read votes
    /// for its own value and for each less specific version of it, so two
    /// reads that both lost a level still confirm the item and quantity.
    private struct Slot: Sendable {
        struct Run: Sendable {
            let value: GearDropEntry
            var first: Double
            var last: Double
            var count = 1
        }
        var runs: [Run] = []
        var confirmed: [GearDropEntry] = []
        /// A contradicting read since the last read of the resolved value.
        var conflictPending = false
        /// Each read's quantity colour, by the quantity it was read with.
        /// Colour is voted apart from the entry: an unclear or contradicting
        /// colour leaves the item unmarked, never unread.
        var colors: [(quantity: Int, multiplied: Bool)] = []

        /// Multiplied or not, once two reads of the settled quantity agree
        /// and none contradicts them.
        func multiplied(for entry: GearDropEntry) -> Bool? {
            let reads = colors.filter { $0.quantity == entry.quantity }.map(\.multiplied)
            let red = reads.filter { $0 }.count, white = reads.count - red
            if red >= 2 && white == 0 { return true }
            if white >= 2 && red == 0 { return false }
            return nil
        }

        /// The most specific confirmed value, or nil when two confirmed
        /// values contradict each other.
        var resolved: GearDropEntry? {
            guard var best = confirmed.first else { return nil }
            for value in confirmed.dropFirst() {
                if value.refines(best) { best = value }
                else if !best.refines(value) { return nil }
            }
            return best
        }

        /// The panel was away for `duration`: that time does not count
        /// towards the reading gap of the reads taken before it left.
        mutating func pause(for duration: Double) {
            for index in runs.indices { runs[index].last += duration }
        }

        mutating func accept(_ entry: GearDropEntry, at time: Double, policy: Policy) {
            let supported = entry.generalizations
            var next: [Run] = []
            for var run in runs {
                if supported.contains(run.value) {
                    if time - run.last > policy.maximumReadingGap + 1e-9 { run.first = time; run.count = 0 }
                    run.last = time; run.count += 1
                } else if run.value.refines(entry) {
                    // Lost detail is not a contradiction, and not a vote.
                    // Keep the last supporting timestamp: missing detail must
                    // neither extend agreement nor bridge a reading gap.
                } else { continue }
                next.append(run)
            }
            for value in supported where !next.contains(where: { $0.value == value }) {
                next.append(Run(value: value, first: time, last: time))
            }
            runs = next
            for run in runs where run.count >= 2 && run.last - run.first + 1e-9 >= policy.minimumSpan
                && !confirmed.contains(run.value) {
                confirmed.append(run.value)
            }
            if let resolved {
                if entry == resolved || entry.refines(resolved) || resolved.refines(entry) { conflictPending = false }
                else { conflictPending = true }
            }
        }
    }

    public let policy: Policy
    private var nextGroupID = 1
    private var groupID: Int?
    private var startedAt = 0.0
    private var lastReading = -Double.infinity
    private var closedThrough = -Double.infinity
    private var currentStage: GearDropStage?
    private var panels: [GearDropSummary.Panel] = []
    private var slots: [Int: Slot] = [:]
    /// The fewest unparsed rows in any read of this panel. A row hidden in
    /// every read keeps the panel partial; one crossed once by floating AP
    /// text does not.
    private var fewestUnreadableRows: Int?
    /// Effects use the same agreement and contradiction rules as item names.
    private var effectSlot: Slot?
    private var absentSince: Double?
    /// First absent source frame once the departure span is established.
    /// Late reads cannot erase this boundary or carry a new panel into it.
    private var departedAt: Double?
    /// A departed Bonus panel with rows unconfirmed, kept open in case it
    /// was only hidden. `closeTime` is when the group would have closed.
    private struct Hold: Sendable {
        let since: Double
        let closeTime: Double
        var returnedAt: Double?
        var absentAgainSince: Double?
    }
    private var hold: Hold?
    /// A group holds at most once: a panel that leaves again closes it.
    private var hasHeld = false
    /// Open, or held after its Bonus panel left: either way not yet published.
    public var isObserving: Bool { groupID != nil }
    /// The panel being read has every row it showed confirmed, and no read of
    /// it left a row unparsed: more reads of it can't add an item.
    public var currentPanelSettled: Bool { hold == nil && currentPanel()?.partial == false }

    public init(policy: Policy = Policy()) { self.policy = policy }

    /// Cheap geometry can establish a departure only on analyzed source frames.
    /// A missed OCR read or a covered panel is not an absent panel.
    public mutating func observe(at time: Double, panelCandidate: Bool, continuityLost: Bool = false,
                                 pendingReadSourceTime: Double? = nil) -> GearDropSummary? {
        if continuityLost { return loseContinuity(at: time) }
        guard time.isFinite, groupID != nil, time >= startedAt else { return nil }
        if hold != nil { return observeHeld(at: time, panelCandidate: panelCandidate, pending: pendingReadSourceTime) }
        if panelCandidate {
            if let absentSince, time - absentSince + 1e-9 >= policy.departureSpan {
                return leave(at: time, since: absentSince, returned: true)
            }
            absentSince = nil
        } else {
            absentSince = absentSince ?? time
            if time - absentSince! + 1e-9 >= policy.departureSpan { departedAt = absentSince }
        }
        let draining = pendingReadSourceTime.map {
            $0.isFinite && $0 >= startedAt && $0 >= closedThrough && $0 <= time
                && $0 < (absentSince ?? .infinity)
                && time - $0 <= policy.maximumCompletionWait
        } ?? false
        if time - startedAt > policy.groupLimit {
            return draining ? nil : finish(at: time, reason: "groupTimeout")
        }
        if let departedAt, !draining { return leave(at: time, since: departedAt, returned: false) }
        return nil
    }

    /// The panel left. A Bonus panel with rows unconfirmed holds the group
    /// open instead of closing it, once per group.
    private mutating func leave(at time: Double, since: Double, returned: Bool) -> GearDropSummary? {
        guard !hasHeld, currentStage == .bonus, currentPanel()?.partial == true else {
            return finish(at: time, reason: "panelLeft")
        }
        hasHeld = true
        hold = Hold(since: since, closeTime: time, returnedAt: returned ? time : nil)
        return nil
    }

    /// While held, geometry only notes whether a panel came back; a read
    /// decides whether it is the Bonus panel (it joins) or not (it closes).
    private mutating func observeHeld(at time: Double, panelCandidate: Bool, pending: Double?) -> GearDropSummary? {
        guard var away = hold else { return nil }
        let deadline = away.closeTime + policy.bonusReturnWindow
        if panelCandidate {
            if away.returnedAt == nil, time <= deadline + 1e-9 { away.returnedAt = time }
            away.absentAgainSince = nil
        } else if away.returnedAt != nil {
            away.absentAgainSince = away.absentAgainSince ?? time
        }
        hold = away
        // Wait for a read taken before the deadline: it may be the panel's.
        let waiting = pending.map {
            $0.isFinite && $0 >= startedAt && $0 >= closedThrough && $0 <= time
                && $0 <= deadline && time - $0 <= policy.maximumCompletionWait
        } ?? false
        if !waiting, time > deadline || time - startedAt > policy.groupLimit {
            return finish(at: time, reason: "panelLeft")
        }
        return nil
    }

    /// A Bonus read of the held panel: the group continues, and the time it
    /// was away does not count against its earlier reads.
    private mutating func resume(at time: Double) {
        guard let away = hold else { return }
        let duration = max(0, min(away.returnedAt ?? time, time) - away.since)
        for key in slots.keys { slots[key]?.pause(for: duration) }
        effectSlot?.pause(for: duration)
        hold = nil; departedAt = nil
        absentSince = away.absentAgainSince
    }

    /// Reject pre-gap OCR even when no group was open at the interruption.
    public mutating func loseContinuity(at time: Double) -> GearDropSummary? {
        guard time.isFinite else { return nil }
        let closed = finish(at: time, reason: "continuityLost")
        closedThrough = max(closedThrough, time)
        return closed
    }

    public mutating func accept(_ evidence: GearDropFrameEvidence) -> GearDropSummary? {
        let time = evidence.sourceTime
        guard time.isFinite else { readingDisposition = .invalidTime; return nil }
        guard time >= closedThrough else { readingDisposition = .closedInterval; return nil }
        guard time > lastReading else { readingDisposition = .outOfOrder; return nil }
        lastReading = time
        // An unread or excluded title says nothing about the current panel's
        // rows; it neither confirms nor contradicts them.
        guard evidence.stage == .portal || evidence.stage == .bonus else {
            readingDisposition = .nonPanel
            return nil
        }
        readingDisposition = .accepted
        var closed: GearDropSummary?
        if hold == nil, let departedAt, time >= departedAt, evidence.stage == .bonus {
            // Read on a frame after the departure: the panel came back.
            closed = leave(at: time, since: departedAt, returned: true)
        }
        if let away = hold, time >= away.since {
            // Only the Bonus panel, back in time, joins; a portal panel is
            // the next drop and never does.
            if evidence.stage == .bonus, time <= away.closeTime + policy.bonusReturnWindow + 1e-9 {
                resume(at: time)
            } else {
                closed = finish(at: time, reason: "panelLeft")
            }
        } else if hold == nil, let departedAt, time >= departedAt {
            closed = finish(at: time, reason: "panelLeft")
        } else if currentStage == .bonus, evidence.stage == .portal {
            closed = finish(at: time, reason: "nextPortalPanel")
        }
        if groupID == nil {
            groupID = nextGroupID; nextGroupID += 1; startedAt = time
        }
        // A completion taken before the first absent frame supplies rows,
        // not fresh geometry. Only a source frame in this interval can clear
        // an unconfirmed absence; established departures close above.
        if let absentSince, time >= absentSince { self.absentSince = nil }
        if currentStage != evidence.stage {
            savePanel()
            currentStage = evidence.stage
        }
        for entry in evidence.entries {
            slots[entry.position, default: Slot()].accept(entry.withMultiplied(nil), at: time, policy: policy)
            if let multiplied = entry.multiplied {
                slots[entry.position]?.colors.append((entry.quantity, multiplied))
            }
        }
        fewestUnreadableRows = min(fewestUnreadableRows ?? evidence.unreadableRows, evidence.unreadableRows)
        for effect in evidence.effects ?? [] where effect == "ITO EN (+)" || effect == "ITO EN (-)" {
            if effectSlot == nil { effectSlot = Slot() }
            effectSlot?.accept(GearDropEntry(column: 0, row: 0, item: effect,
                levelState: .notApplicable, level: nil, quantity: 1), at: time, policy: policy)
        }
        return closed
    }

    public mutating func finish(at time: Double, reason: String) -> GearDropSummary? {
        guard let groupID, time.isFinite, time >= startedAt else { return nil }
        var time = time, reason = reason
        if let hold {
            // A held panel had already left: the group ends when it did.
            time = max(startedAt, min(time, hold.closeTime)); reason = "panelLeft"
        }
        savePanel()
        if reason == "continuityLost" {
            for index in panels.indices { panels[index].partial = true }
        }
        let summary = GearDropSummary(groupID: groupID, startedAt: startedAt, closedAt: time,
            closeReason: reason, hackID: nil, association: .unassociated, panels: panels)
        self.groupID = nil; currentStage = nil; panels = []; absentSince = nil; departedAt = nil
        hold = nil; hasHeld = false
        closedThrough = time
        return summary
    }

    private mutating func savePanel() {
        if let panel = currentPanel() { panels.append(panel) }
        slots = [:]; fewestUnreadableRows = nil; effectSlot = nil
    }

    /// The current panel as it would be saved now.
    private func currentPanel() -> GearDropSummary.Panel? {
        if let currentStage {
            let settled = slots.sorted { $0.key < $1.key }.map(\.value).map { slot -> GearDropEntry? in
                guard !slot.conflictPending, let entry = slot.resolved else { return nil }
                return entry.withMultiplied(slot.multiplied(for: entry))
            }
            let entries = settled.compactMap { $0 }
            // Every position seen must settle; a quantity is never inferred.
            let effect = effectSlot?.conflictPending == false ? effectSlot?.resolved?.item : nil
            let partial = entries.isEmpty || entries.count != settled.count || (fewestUnreadableRows ?? 1) > 0
                || (effectSlot != nil && effect == nil)
            // An unread rarity meter is missing detail, like an unread level:
            // the item and quantity still count, and the panel is not partial.
            return .init(stage: currentStage, entries: entries, partial: partial, effects: effect.map { [$0] })
        }
        return nil
    }
}

extension GearDropEntry {
    /// True when this entry says everything `other` says and possibly more:
    /// the same place and quantity, with a level, name or rarity where `other` has
    /// none. Contradictory values never refine each other.
    func refines(_ other: GearDropEntry) -> Bool {
        guard self != other, column == other.column, row == other.row, quantity == other.quantity else { return false }
        let item = other.item == nil || other.item == item
        let level = other.levelState == .unreadable || (other.levelState == levelState && other.level == level)
        let rarity = other.rarity == nil || other.rarity == .unreadable || other.rarity == rarity
        return item && level && rarity
    }

    /// This entry and each version with its name, level or rarity unread.
    var generalizations: [GearDropEntry] {
        var values = [self]
        func add(_ value: GearDropEntry) { if !values.contains(value) { values.append(value) } }
        add(GearDropEntry(column: column, row: row, item: nil, levelState: levelState, level: level, quantity: quantity, rarity: rarity))
        add(GearDropEntry(column: column, row: row, item: item, levelState: .unreadable, level: nil, quantity: quantity, rarity: rarity))
        add(GearDropEntry(column: column, row: row, item: nil, levelState: .unreadable, level: nil, quantity: quantity, rarity: rarity))
        if let rarity, rarity != .unreadable {
            for value in values { add(value.withRarity(.unreadable)) }
        }
        return values
    }
}
