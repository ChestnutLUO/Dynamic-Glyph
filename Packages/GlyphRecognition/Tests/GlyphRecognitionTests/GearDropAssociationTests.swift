import Testing
@testable import GlyphRecognition

/// A tester's session (TestFlight build 95, iPhone18,1, English game, Glyph
/// assistance): two Glyph hacks, whose drops the game then showed back to
/// back. Pickup sparks covered the first drop's Bonus panel's left side and
/// bottom edge, so the detector lost the panel for about 1.1 s while it stayed
/// on screen. One frame found it again just before it left; that read opened a
/// second, empty group, which took hack 2's wait, and hack 2's own drop was
/// saved as claimed by no hack. The read of the panel found again carried
/// the same three rows as the panel's one earlier read, 1.8 s before.
@Suite("Gear drop association")
struct GearDropAssociationTests {
    struct Read: Sendable {
        let time: Double
        let stage: GearDropStage
        let entries: [GearDropEntry]
        var unreadable = 0
        /// Source time to completion. One Bonus read took 0.93 s.
        var latency = 0.03
        var evidence: GearDropFrameEvidence {
            .init(sourceTime: time, stage: stage, entries: entries, unreadableRows: unreadable)
        }
    }

    static func item(_ column: Int, _ row: Int, _ name: String, level: Int?, _ quantity: Int,
                     rarity: GearDropEntry.Rarity? = nil, multiplied: Bool? = false) -> GearDropEntry {
        GearDropEntry(column: column, row: row, item: name, levelState: level == nil ? .notApplicable : .known,
                      level: level, quantity: quantity, rarity: rarity, multiplied: multiplied)
    }

    /// Every reading in the session's `gear-drops.jsonl`, as logged, or with
    /// the read of the panel found again replaced by `refound`.
    static func reads(refound: [GearDropEntry]? = nil, refoundUnreadable: Int = 0) -> [Read] {
        let firstPortal = [item(0, 0, "Resonator", level: 8, 1)]
        // The second read left two quantity colours unclear.
        func firstBonus(_ colour: Bool?) -> [GearDropEntry] {
            [item(0, 0, "XMP Burster", level: 8, 3, multiplied: colour), item(1, 0, "Resonator", level: 8, 3),
             item(0, 1, "Resonator", level: 7, 1, multiplied: colour)]
        }
        let secondPortal = [item(0, 0, "Portal Shield", level: nil, 1, rarity: .common),
                            item(1, 0, "Power Cube", level: 6, 1), item(0, 1, "Resonator", level: 6, 1)]
        let secondBonus = [item(0, 0, "Portal Shield", level: nil, 1, rarity: .common),
                           item(1, 0, "XMP Burster", level: 6, 6), item(0, 1, "Resonator", level: 6, 5)]
        var reads = [123347.79701279099, 123347.997046708, 123348.197080791, 123348.39711479101,
                     123348.597148791, 123348.79718279099, 123348.997216708, 123349.19725070801,
                     123349.397284791, 123349.597318791].map { Read(time: $0, stage: .portal, entries: firstPortal) }
        reads.append(Read(time: 123349.847361291, stage: .bonus, entries: firstBonus(false), unreadable: 1,
                          latency: 0.93))
        // The only read of the panel after the detector lost it.
        reads.append(Read(time: 123351.647667208, stage: .bonus, entries: refound ?? firstBonus(nil),
                          unreadable: refoundUnreadable, latency: 0.18))
        reads.append(Read(time: 123352.747854291, stage: .portal, entries: secondPortal, unreadable: 1,
                          latency: 0.7))
        reads += [123353.497981708, 123353.698015791, 123353.898049708, 123354.098083708,
                  123354.29811770799, 123354.49815179101, 123354.698185791]
            .map { Read(time: $0, stage: .portal, entries: secondPortal) }
        reads += [123354.89821979099, 123355.098253708, 123355.298287791, 123355.498321708,
                  123355.69835570799, 123355.89838979099, 123356.098423791, 123356.298457791,
                  123356.498491708, 123356.698525791]
            .map { Read(time: $0, stage: .bonus, entries: secondBonus) }
        return reads
    }

    /// Panel geometry: the detector on every frame of the session's video
    /// (the first drop's portal panel, one transition frame, its Bonus panel
    /// until the sparks hid it at 123350.597, and the second drop), plus the
    /// one live frame that found the first Bonus panel again, 123351.647:
    /// the read logged for it needs a panel there.
    static func panelShown(at time: Double) -> Bool {
        (123347.74...123349.70).contains(time) || (123349.79...123350.55).contains(time)
            || (123351.64...123351.65).contains(time) || (123352.74...123356.70).contains(time)
    }

    /// The session's frames at 20 Hz; a completed read is taken before the
    /// frame's geometry, as in the app.
    static func groups(_ reads: [Read]) -> [GearDropSummary] {
        var tracker = GearDropTracker()
        var pending = reads[...]
        var closed: [GearDropSummary] = []
        // Frames at 20 Hz; a completed read is taken before the frame's geometry.
        for step in 0..<200 {
            let time = 123347.797013 + Double(step) * 0.05
            while let read = pending.first, read.time + read.latency <= time {
                if let group = tracker.accept(read.evidence) { closed.append(group) }
                pending = pending.dropFirst()
            }
            let inFlight = pending.first.flatMap { $0.time <= time ? $0.time : nil }
            if let group = tracker.observe(at: time, panelCandidate: Self.panelShown(at: time),
                                           pendingReadSourceTime: inFlight) { closed.append(group) }
        }
        #expect(pending.isEmpty)
        return closed
    }

    @Test("The Bonus panel found again joins its drop, and its second read confirms hack 1's Bonus items")
    func refoundBonusPanel() throws {
        let closed = Self.groups(Self.reads())
        var session = GearDropObservationSession()
        session.enqueue(hackID: 1, at: 123327.835325125)
        session.enqueue(hackID: 2, at: 123344.138057541)
        var display = GearDropDisplayTracker()
        let attached = closed.map { closedGroup -> GearDropSummary in
            let group = session.close(closedGroup)
            display.finished(group)
            display.update(waiting: session.waiting, reading: false, associationUncertain: false, at: group.closedAt)
            return group
        }
        try #require(attached.count == 2)
        let first = attached[0], second = attached[1]

        // The two Bonus reads were 1.8 s apart, 1.05 s of it with the panel
        // hidden: 0.75 s on screen, within the reading gap.
        #expect(first.hackID == 1 && first.association == .ordered && first.closeReason == "panelLeft")
        #expect(first.panels.map(\.stage) == [.portal, .bonus])
        #expect(first.panels.map(\.partial) == [false, false])
        #expect(first.panels[1].entries.map { "L\($0.level ?? 0) \($0.item ?? "?") x\($0.quantity)" }
                == ["L8 XMP Burster x3", "L8 Resonator x3", "L7 Resonator x1"])
        #expect(first.bothPanelsRead && first.recognizedQuantity == 8)
        // It closes when the panel found again leaves.
        #expect(abs(first.closedAt - 123351.847) < 0.01)

        #expect(second.hackID == 2 && second.association == .ordered)
        #expect(second.bothPanelsRead && second.recognizedQuantity == 15)
        #expect(second.panels.map { $0.entries.map(\.item) }
                == [["Portal Shield", "Power Cube", "Resonator"], ["Portal Shield", "XMP Burster", "Resonator"]])
        #expect(session.waiting.isEmpty)
        #expect(display.display == GearDropDisplay(state: .read, hackID: 2, itemCount: 15))
    }

    @Test("A Bonus panel found again that reads nothing still leaves the next hack its own drop")
    func refoundBonusPanelUnread() throws {
        let closed = Self.groups(Self.reads(refound: [], refoundUnreadable: 3))
        var session = GearDropObservationSession()
        session.enqueue(hackID: 1, at: 123327.835325125)
        session.enqueue(hackID: 2, at: 123344.138057541)
        var display = GearDropDisplayTracker()
        var attached: [GearDropSummary] = []
        for group in closed {
            let group = session.close(group)
            display.finished(group)
            display.update(waiting: session.waiting, reading: false, associationUncertain: false, at: group.closedAt)
            attached.append(group)
            if attached.count == 1 {
                #expect(display.display == GearDropDisplay(state: .partial, hackID: 1, itemCount: 1))
            }
        }
        try #require(attached.count == 2)
        let first = attached[0], second = attached[1]
        // As in the log, the first drop's Bonus panel is partial; but no
        // second group takes hack 2's wait.
        #expect(first.hackID == 1 && first.association == .ordered)
        #expect(first.panels.map(\.stage) == [.portal, .bonus] && first.recognizedQuantity == 1)
        #expect(first.panels[1].entries.isEmpty && first.panels[1].partial)
        #expect(second.hackID == 2 && second.association == .ordered && second.recognizedQuantity == 15)
        #expect(session.waiting.isEmpty)
    }

    @Test("Without the hold, the panel found again opens an empty group that claims no hack")
    func repeatedBonusPanel() throws {
        // The first two groups as build 95 logged them, before the hold. A
        // group whose Bonus rows were confirmed still closes at once, so the
        // same panel found again can still open a group like the second.
        let bonus = GearDropSummary.Panel(stage: .bonus, entries: [], partial: true)
        let firstPanels = [GearDropSummary.Panel(stage: .portal, entries: [Self.item(0, 0, "Resonator", level: 8, 1)],
                                                 partial: false), bonus]
        let closed = [
            GearDropSummary(groupID: 1, startedAt: 123347.797, closedAt: 123350.797, closeReason: "panelLeft",
                            hackID: nil, association: .unassociated, panels: firstPanels),
            GearDropSummary(groupID: 2, startedAt: 123351.648, closedAt: 123351.998, closeReason: "panelLeft",
                            hackID: nil, association: .unassociated, panels: [bonus]),
        ] + Self.groups(Self.reads()).dropFirst()
        var session = GearDropObservationSession()
        session.enqueue(hackID: 1, at: 123327.835325125)
        session.enqueue(hackID: 2, at: 123344.138057541)
        var display = GearDropDisplayTracker()
        var attached: [GearDropSummary] = []
        for group in closed {
            let group = session.close(group)
            display.finished(group)
            display.update(waiting: session.waiting, reading: false, associationUncertain: false, at: group.closedAt)
            attached.append(group)
            if attached.count == 2 {
                // The repeated panel leaves hack 1's completion on screen.
                #expect(display.display == GearDropDisplay(state: .partial, hackID: 1, itemCount: 1))
            }
        }
        try #require(attached.count == 3)
        let first = attached[0], repeated = attached[1], second = attached[2]
        #expect(first.hackID == 1 && first.association == .ordered)

        #expect(repeated.panels.map(\.stage) == [.bonus] && repeated.panels[0].entries.isEmpty)
        #expect(repeated.hackID == nil && repeated.association == .repeatedBonus)

        #expect(second.hackID == 2 && second.association == .ordered)
        #expect(second.bothPanelsRead && second.recognizedQuantity == 15)
        #expect(second.panels.map { $0.entries.map(\.item) }
                == [["Portal Shield", "Power Cube", "Resonator"], ["Portal Shield", "XMP Burster", "Resonator"]])
        #expect(session.waiting.isEmpty)
    }

    @Test("An empty Bonus-only group still takes the wait unless it closely follows a Bonus panel")
    func emptyBonusStillClaims() {
        let row = GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 6, quantity: 2)
        let portal = GearDropSummary.Panel(stage: .portal, entries: [row], partial: false)
        let readBonus = GearDropSummary.Panel(stage: .bonus, entries: [row], partial: false)
        let emptyBonus = GearDropSummary.Panel(stage: .bonus, entries: [], partial: true)
        let emptyPortal = GearDropSummary.Panel(stage: .portal, entries: [], partial: true)
        // The previous group's panels (it closes at 10 s), the next group's
        // start, its panels, and whether it takes the next wait.
        let cases: [([GearDropSummary.Panel]?, Double, [GearDropSummary.Panel], Bool)] = [
            (nil, 10.5, [emptyBonus], true),                      // the capture's first group
            ([portal], 10.5, [emptyBonus], true),                 // after a portal-only group
            ([portal, readBonus], 12.5, [emptyBonus], true),      // too late to be that panel
            ([portal, readBonus], 10.5, [readBonus], true),       // a row was read
            ([portal, readBonus], 10.5, [emptyPortal, emptyBonus], true), // a new drop's portal panel
            ([portal, readBonus], 10.5, [emptyBonus], false),
        ]
        for (index, (previous, start, panels, claims)) in cases.enumerated() {
            var session = GearDropObservationSession()
            session.enqueue(hackID: 1, at: 0); session.enqueue(hackID: 2, at: 1)
            if let previous {
                let earlier = session.close(GearDropSummary(groupID: 1, startedAt: 8, closedAt: 10,
                    closeReason: "panelLeft", hackID: nil, association: .unassociated, panels: previous))
                #expect(earlier.hackID == 1, "case \(index)")
            }
            let next = session.close(GearDropSummary(groupID: 2, startedAt: start, closedAt: start + 0.5,
                closeReason: "panelLeft", hackID: nil, association: .unassociated, panels: panels))
            if claims {
                #expect(next.hackID == (previous == nil ? 1 : 2) && next.association == .ordered, "case \(index)")
            } else {
                #expect(next.hackID == nil && next.association == .repeatedBonus, "case \(index)")
                #expect(session.waiting.map(\.hackID) == [2], "case \(index)")
            }
        }
    }
}

/// A Bonus panel that leaves with rows unconfirmed holds its group open for
/// `bonusReturnWindow`, in case it was only hidden. Frames every 0.05 s;
/// each read completes one frame after its own.
@Suite("Gear drop Bonus panel hold")
struct GearDropBonusHoldTests {
    static let rows = [
        GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .known, level: 8, quantity: 3),
        GearDropEntry(column: 1, row: 0, item: "Resonator", levelState: .known, level: 8, quantity: 3),
    ]
    static func time(_ frame: Int) -> Double { Double(frame) * 0.05 }
    static func portal(_ frame: Int, quantity: Int = 1) -> GearDropFrameEvidence {
        .init(sourceTime: time(frame), stage: .portal, entries: [
            GearDropEntry(column: 0, row: 0, item: "Resonator", levelState: .known, level: 8, quantity: quantity)
        ])
    }
    static func bonus(_ frame: Int, _ entries: [GearDropEntry] = rows, unreadable: Int = 0) -> GearDropFrameEvidence {
        .init(sourceTime: time(frame), stage: .bonus, entries: entries, unreadableRows: unreadable)
    }

    /// The groups returned, with the frame time each was returned at.
    static func play(_ reads: [GearDropFrameEvidence], shown: (Int) -> Bool, frames: Int = 120,
                     continuityLostAt lost: Int? = nil,
                     watch: (Int, GearDropTracker) -> Void = { _, _ in }) -> [(time: Double, group: GearDropSummary)] {
        var tracker = GearDropTracker()
        var pending = reads[...]
        var closed: [(time: Double, group: GearDropSummary)] = []
        for frame in 0...frames {
            let now = time(frame)
            while let read = pending.first, read.sourceTime + 0.05 <= now + 1e-9 {
                if let group = tracker.accept(read) { closed.append((now, group)) }
                pending = pending.dropFirst()
            }
            let inFlight = pending.first.flatMap { $0.sourceTime <= now ? $0.sourceTime : nil }
            if let group = tracker.observe(at: now, panelCandidate: shown(frame), continuityLost: frame == lost,
                                           pendingReadSourceTime: inFlight) { closed.append((now, group)) }
            watch(frame, tracker)
        }
        return closed
    }

    @Test("A Bonus panel lost and found again within the window joins its group")
    func joins() throws {
        // Hidden from 1.5 s to 2.6 s: the two Bonus reads are 1.6 s apart,
        // 0.5 s of it on screen.
        var heldOpen = true
        let closed = Self.play([Self.portal(0), Self.portal(4), Self.bonus(20), Self.bonus(52)],
                               shown: { $0 < 30 || (52..<56).contains($0) },
                               watch: { frame, tracker in if (33...52).contains(frame) { heldOpen = heldOpen && tracker.isObserving } })
        try #require(closed.count == 1)
        let group = closed[0].group
        #expect(heldOpen)
        #expect(group.closeReason == "panelLeft" && abs(group.closedAt - 2.95) < 1e-6)
        #expect(group.panels.map(\.stage) == [.portal, .bonus] && group.panels.map(\.partial) == [false, false])
        #expect(group.bothPanelsRead && group.recognizedQuantity == 7)
    }

    @Test("Time on screen still bounds the reading gap of a panel found again")
    func onScreenGap() throws {
        // Reads 1.7 s apart, 0.3 s of it hidden: 1.4 s on screen is too stale.
        let closed = Self.play([Self.bonus(2), Self.bonus(36)], shown: { $0 < 30 || (36..<40).contains($0) })
        try #require(closed.count == 1)
        #expect(closed[0].group.panels.count == 1)
        #expect(closed[0].group.panels[0].entries.isEmpty && closed[0].group.panels[0].partial)
        #expect(abs(closed[0].group.closedAt - 2.15) < 1e-6)
    }

    @Test("A portal panel within the window never joins: the held group closes when its panel left")
    func portalNeverJoins() throws {
        let closed = Self.play([Self.portal(0), Self.portal(4), Self.bonus(20), Self.portal(52, quantity: 2),
                                Self.portal(56, quantity: 2)],
                               shown: { $0 < 30 || (52..<70).contains($0) })
        try #require(closed.count == 2)
        let (held, next) = (closed[0], closed[1])
        // Published as soon as the portal read completes, with the close time it would have had.
        #expect(abs(held.time - 2.65) < 1e-6 && abs(held.group.closedAt - 1.65) < 1e-6)
        #expect(held.group.closeReason == "panelLeft" && held.group.recognizedQuantity == 1)
        #expect(held.group.panels.map(\.stage) == [.portal, .bonus] && held.group.panels[1].partial)
        #expect(abs(next.group.startedAt - 2.6) < 1e-6 && next.group.panels.map(\.stage) == [.portal])
        #expect(next.group.recognizedQuantity == 2)
    }

    @Test("With no panel back, the held group closes at its departure time once the window passes")
    func windowPasses() throws {
        var lastObserving = 0
        let closed = Self.play([Self.portal(0), Self.portal(4), Self.bonus(20)], shown: { $0 < 30 },
                               watch: { frame, tracker in if tracker.isObserving { lastObserving = frame } })
        try #require(closed.count == 1)
        // Departure at 1.65 s; the window ends at 3.65 s.
        #expect((72...74).contains(lastObserving) && (3.65...3.75).contains(closed[0].time))
        #expect(abs(closed[0].group.closedAt - 1.65) < 1e-6 && closed[0].group.closeReason == "panelLeft")
        #expect(closed[0].group.panels.map(\.partial) == [false, true])
    }

    @Test("A Bonus panel whose rows are confirmed closes at departure, as before")
    func confirmedClosesAtOnce() throws {
        let closed = Self.play([Self.portal(0), Self.portal(4), Self.bonus(20), Self.bonus(24)], shown: { $0 < 30 })
        try #require(closed.count == 1)
        #expect(abs(closed[0].time - 1.65) < 1e-6 && abs(closed[0].group.closedAt - 1.65) < 1e-6)
        #expect(closed[0].group.bothPanelsRead && closed[0].group.recognizedQuantity == 7)
    }

    @Test("A capture gap while held closes the group as its panel left")
    func continuityLostWhileHeld() throws {
        let closed = Self.play([Self.portal(0), Self.portal(4), Self.bonus(20)], shown: { $0 < 30 },
                               continuityLostAt: 40)
        try #require(closed.count == 1)
        #expect(abs(closed[0].time - 2) < 1e-6 && abs(closed[0].group.closedAt - 1.65) < 1e-6)
        #expect(closed[0].group.closeReason == "panelLeft")
        #expect(closed[0].group.panels.map(\.partial) == [false, true])
    }

    @Test("A confirmed panel found again empty opens a group that claims no hack")
    func confirmedThenFoundAgain() throws {
        let closed = Self.play([Self.portal(0), Self.portal(4), Self.bonus(20), Self.bonus(24),
                                Self.bonus(52, [], unreadable: 2)],
                               shown: { $0 < 30 || (52..<56).contains($0) })
        try #require(closed.count == 2)
        var session = GearDropObservationSession()
        session.enqueue(hackID: 1, at: -10); session.enqueue(hackID: 2, at: -5)
        let first = session.close(closed[0].group), again = session.close(closed[1].group)
        #expect(first.hackID == 1 && first.recognizedQuantity == 7)
        #expect(abs(again.closedAt - 2.95) < 1e-6)
        #expect(again.hackID == nil && again.association == .repeatedBonus)
        #expect(session.waiting.map(\.hackID) == [2])
    }
}
