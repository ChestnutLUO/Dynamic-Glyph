import Foundation
import Testing
@testable import GlyphRecognition

@Suite("Gear summary recognition")
struct GearDropRecognitionTests {
    let parser = GearDropTextParser()
    let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.46)
    func line(_ text: String, x: Double = 0.1, y: Double = 0.35, width: Double = 0.35,
              confidence: Double = 1) -> ResultTextLine {
        ResultTextLine(text: text, confidence: confidence, x: x, y: y, width: width, height: 0.014)
    }
    func frame(_ time: Double, stage: GearDropStage = .portal, quantity: Int = 2,
               unreadable: Int = 0) -> GearDropFrameEvidence {
        .init(sourceTime: time, stage: stage, entries: [
            GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .known, level: 6, quantity: quantity)
        ], unreadableRows: unreadable)
    }

    @Test("Level, rarity bars, explicit quantities and truncated names stay separate")
    func entryGrammar() {
        #expect(parser.parseEntry("L6 x8 XMP Burster", row: 0, column: 0)?.level == 6)
        for bars in ["//", "III", "11", "111"] {
            let turret = parser.parseEntry("\(bars) x1 Turret", row: 0, column: 0)
            #expect(turret?.level == nil && turret?.levelState == .notApplicable)
        }
        #expect(parser.parseEntry("x1 Portal Key", row: 0, column: 0)?.levelState == .notApplicable)
        // iOS Vision loses or misreads the coloured L of a levelled item.
        for (text, level) in [("6 x8 XMP Burster", 6), ("15 x2 XMP Burster", 5), ("1*)8 x1 XMP Burster", 8),
                              ("(*) 15 x2 XMP Burster", 5), ("L* L7 x1 XMP Burster", 7)] {
            #expect(parser.parseEntry(text, row: 0, column: 0)?.level == level)
        }
        #expect(parser.parseEntry("68 x1 Resonator", row: 0, column: 0)?.levelState == .unreadable)
        // Without a known levelled name, only an explicit L counts.
        #expect(parser.parseEntry("15 x2 New item", row: 0, column: 0)?.level == nil)
        #expect(parser.parseEntry("L5 x2 New item", row: 0, column: 0)?.level == 5)
        #expect(parser.parseEntry("L9 x8 XMP Burster", row: 0, column: 0)?.level == nil)
        #expect(parser.parseEntry("x2 ITO EN Tr…", row: 0, column: 0)?.item == nil)
        // As Vision read a player's panel: three rarity bars, then the short name.
        for row in ["/// x1 ITO EN (-)", "\"4 /ll x1 ITO EN (-)"] {
            let transmuter = parser.parseEntry(row, row: 0, column: 0)
            #expect(transmuter?.item == "ITO EN Transmuter (-)" && transmuter?.quantity == 1, "\(row)")
            #expect(transmuter?.levelState == .notApplicable && transmuter?.rarity == .veryRare, "\(row)")
        }
        #expect(parser.parseEntry("/// x1 ITO EN (+)", row: 0, column: 0)?.item == "ITO EN Transmuter (+)")
        #expect(parser.parseEntry("x2 New item", row: 0, column: 0)?.quantity == 2)
        for invalid in ["L6 XMP Burster", "x0 Turret", "+435 AP", "x1 Turret x2", "x999999 Turret"] {
            #expect(parser.parseEntry(invalid, row: 0, column: 0) == nil)
        }
    }

    @Test("Stage needs its own current title; reward and Chinese titles never become portal")
    func titles() {
        let row = line("L6 x2 XMP Burster")
        let cases: [(String, GearDropStage)] = [("Bonus items:", .bonus), ("Bonvs items:", .unknown),
            ("Bounty Claimed", .excluded), ("Bounty Clalmed", .unknown), ("奖励物品:", .unsupported),
            ("Test location", .portal)]
        for (title, stage) in cases {
            let evidence = parser.read(lines: [line(title, x: 0.3, y: 0.31), row], bounds: bounds, at: 1)
            #expect(evidence.stage == stage)
        }
        #expect(parser.read(lines: [row], bounds: bounds, at: 1).stage == .unknown)
        #expect(parser.read(lines: [line("Bonus items:", y: 0.31, confidence: 0.2), row], bounds: bounds, at: 1).stage == .unknown)
    }

    @Test("A shortened name resolves when it starts exactly one item's name, and only then")
    func kineticAbbreviation() throws {
        for name in ["Kinetic C...", "Kinetic C…", "Kinetic Cap...", "Kinetic Capsul…", "Kinetic..."] {
            let entry = try #require(parser.parseEntry("// x1 \(name)", row: 2, column: 1))
            #expect(entry.item == "Kinetic Capsule")
            #expect(entry.quantity == 1 && entry.levelState == .notApplicable && entry.level == nil)
            #expect(entry.hasRarityMeter && entry.rarity == nil)
        }
        #expect(parser.parseEntry("x2 Portal S…", row: 0, column: 0)?.item == "Portal Shield")
        // Too short, not a start, garbled, not shortened, or both transmuters.
        for name in ["K...", "Kinetic C", "Kinetic Cr...", "Kinetic...Capsule",
                     "Kinetic C......", "ITO EN Tr...", "Portal…", "Unknown..."] {
            let entry = try #require(parser.parseEntry("x1 \(name)", row: 2, column: 1))
            #expect(entry.item == nil && entry.quantity == 1)
        }
        var tracker = GearDropTracker()
        for (time, name) in [(0.0, "Kinetic C..."), (0.2, "Kinetic Capsule")] {
            let entry = try #require(parser.parseEntry("x1 \(name)", row: 2, column: 1))
            _ = tracker.accept(.init(sourceTime: time, stage: .bonus, entries: [entry.withRarity(.rare)]))
        }
        let group = tracker.finish(at: 0.3, reason: "test")
        #expect(group?.recognizedQuantity == 1 && group?.unidentifiedQuantity == 0)
        #expect(group?.panels.first?.entries.first?.rarity == .rare)
    }

    @Test("Columns and rows are positional; animation text below the panel is excluded")
    func positions() {
        let value = parser.read(lines: [line("Bonus items:", y: 0.31),
            line("L6 x2 XMP Burster"), line("L8 x1 Resonator", x: 0.58),
            line("L5 x30 Resonator", y: 0.386), line("L8 x99 Power Cube", y: 0.50)], bounds: bounds, at: 0)
        #expect(value.entries.count == 3)
        #expect(value.entries.map(\.position) == [0, 1, 2])
        #expect(value.entries.map(\.quantity) == [2, 1, 30])
    }

    @Test("Repeated frames count once; portal and bonus contribute independently")
    func counts() throws {
        var tracker = GearDropTracker()
        for t in [0.0, 0.05, 0.1, 0.2] { _ = tracker.accept(frame(t)) }
        for t in [0.3, 0.4, 0.6] { _ = tracker.accept(frame(t, stage: .bonus, quantity: 6)) }
        let resultValue = tracker.finish(at: 0.7, reason: "test")
        let result = try #require(resultValue)
        #expect(result.recognizedQuantity == 8)
        #expect(result.bothPanelsRead)
        #expect(tracker.finish(at: 0.8, reason: "duplicate") == nil)
    }

    @Test("One read, duplicate timestamps and two adjacent 20-Hz frames cannot confirm")
    func shortPanel() throws {
        for times in [[0.0], [0.0, 0.0], [0.0, 0.05]] {
            var tracker = GearDropTracker()
            for time in times { _ = tracker.accept(frame(time)) }
            let resultValue = tracker.finish(at: 0.2, reason: "test")
            let result = try #require(resultValue)
            #expect(result.recognizedQuantity == 0 && result.panels[0].partial)
        }
    }

    @Test("Presentation highlights do not start gear waits before the player finishes input")
    func queueAfterActualInput() {
        var session = GearDropObservationSession()
        session.observe(at: 9.7, hackID: 1, inputVisible: true, inputPhase: .presenting)
        session.observe(at: 9.78, hackID: 1, inputVisible: false, inputPhase: .presenting)
        #expect(session.waiting.isEmpty)
        session.observe(at: 10.39, hackID: 1, inputVisible: true, inputPhase: .input)
        session.observe(at: 16.24, hackID: 1, inputVisible: false, inputPhase: .completed)
        #expect(session.waiting.map(\.hackID) == [1])
        #expect(session.waiting.first?.startedAt == 16.24)
    }

    @Test("A departing panel drains its in-flight Bonus read before publishing the group",
          arguments: [0.3, 1.6])
    func departureDrainsBonus(_ latency: Double) throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.2))
        _ = tracker.accept(frame(1, stage: .bonus, quantity: 6))
        #expect(tracker.observe(at: 1.3, panelCandidate: false) == nil)
        let completion = 1.2 + latency
        #expect(tracker.observe(at: completion, panelCandidate: false, pendingReadSourceTime: 1.2) == nil)
        _ = tracker.accept(frame(1.2, stage: .bonus, quantity: 6))
        #expect(tracker.readingDisposition == .accepted)
        let closed = tracker.observe(at: completion + 0.05, panelCandidate: false)
        let group = try #require(closed)
        #expect(group.bothPanelsRead && group.recognizedQuantity == 8)
    }

    @Test("A stuck OCR read cannot hold a group forever or cross a capture gap")
    func boundedCompletionWait() throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.2))
        _ = tracker.observe(at: 0.3, panelCandidate: false)
        #expect(tracker.observe(at: 0.5, panelCandidate: false, pendingReadSourceTime: 0.25) == nil)
        let closed = tracker.observe(at: 2.3, panelCandidate: false, pendingReadSourceTime: 0.25)
        let group = try #require(closed)
        #expect(group.closeReason == "panelLeft")
        _ = tracker.accept(frame(0.25, stage: .bonus))
        #expect(tracker.readingDisposition == .closedInterval)
        #expect(!tracker.isObserving)

        _ = tracker.accept(frame(3))
        #expect(tracker.observe(at: 3.2, panelCandidate: false, continuityLost: true,
                                pendingReadSourceTime: 3.1)?.closeReason == "continuityLost")
        _ = tracker.accept(frame(3.1, stage: .bonus))
        #expect(!tracker.isObserving)
    }

    @Test("A pending read cannot merge consecutive portal-only drops", arguments: [false, true])
    func pendingDoesNotMergePortalDrops(_ pending: Bool) throws {
        func resonator(_ time: Double) -> GearDropFrameEvidence {
            .init(sourceTime: time, stage: .portal, entries: [
                .init(column: 0, row: 0, item: "Resonator", levelState: .known, level: 6, quantity: 2)
            ])
        }
        var tracker = GearDropTracker()
        _ = tracker.accept(resonator(0)); _ = tracker.accept(resonator(0.1))
        _ = tracker.observe(at: 0.2, panelCandidate: false)
        var groups: [GearDropSummary] = []
        if let closed = tracker.observe(at: 0.4, panelCandidate: false,
                                        pendingReadSourceTime: pending ? 0.15 : nil) { groups.append(closed) }
        // The next panel appears 1.5 seconds after the first left.
        if let closed = tracker.observe(at: 1.7, panelCandidate: true,
                                        pendingReadSourceTime: pending ? 0.15 : nil) { groups.append(closed) }
        if let closed = tracker.accept(frame(1.7, quantity: 5)) { groups.append(closed) }
        _ = tracker.accept(frame(1.9, quantity: 5))
        if let closed = tracker.finish(at: 2, reason: "test") { groups.append(closed) }
        #expect(groups.map(\.recognizedQuantity) == [2, 5])
        #expect(groups.map(\.groupID) == [1, 2])
        #expect(groups[0].panels[0].entries.first?.item == "Resonator")
        #expect(groups.last?.panels[0].entries.first?.item == "XMP Burster")
    }

    @Test("Reads captured at or after departure cannot delay closing", arguments: [0.2, 0.3])
    func pendingOutsideDeparture(_ source: Double) throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.1))
        _ = tracker.observe(at: 0.2, panelCandidate: false)
        let closed = tracker.observe(at: 0.4, panelCandidate: false, pendingReadSourceTime: source)
        #expect(closed?.recognizedQuantity == 2)
        #expect(!tracker.isObserving)
    }

    @Test("A pre-departure completion preserves the boundary when the next panel appears")
    func completionPreservesDeparture() throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.1))
        _ = tracker.observe(at: 0.2, panelCandidate: false)
        _ = tracker.observe(at: 0.4, panelCandidate: false, pendingReadSourceTime: 0.15)
        _ = tracker.accept(frame(0.15))
        #expect(tracker.observe(at: 1.7, panelCandidate: true)?.recognizedQuantity == 2)
        #expect(!tracker.isObserving)
    }

    @Test("A new panel's completion closes the departed group before its rows are accepted")
    func completionAfterDeparture() throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.1))
        _ = tracker.observe(at: 0.2, panelCandidate: false)
        _ = tracker.observe(at: 0.4, panelCandidate: false, pendingReadSourceTime: 0.15)
        #expect(tracker.accept(frame(1.7, quantity: 5))?.recognizedQuantity == 2)
        _ = tracker.accept(frame(1.9, quantity: 5))
        #expect(tracker.finish(at: 2, reason: "test")?.recognizedQuantity == 5)
    }

    @Test("A brief geometry miss does not divide a still-visible panel")
    func transientAbsence() throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.1))
        #expect(tracker.observe(at: 0.2, panelCandidate: false) == nil)
        #expect(tracker.observe(at: 0.25, panelCandidate: true, pendingReadSourceTime: 0.15) == nil)
        _ = tracker.accept(frame(0.3))
        #expect(tracker.finish(at: 0.4, reason: "test")?.recognizedQuantity == 2)
    }

    @Test("An OCR latency spike cannot combine consecutive portal drops",
          arguments: [0.025, 0.3, 0.5])
    func delayedLaneKeepsGroupsSeparate(_ latency: Double) throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.1))
        var pending: (readyAt: Double, evidence: GearDropFrameEvidence)? = (0.15 + latency, frame(0.15))
        var lastSubmission = -Double.infinity
        var groups: [GearDropSummary] = []
        for tick in 4...28 {
            let time = Double(tick) * 0.05
            if let ready = pending, time + 1e-9 >= ready.readyAt {
                if let closed = tracker.accept(ready.evidence) { groups.append(closed) }
                pending = nil
            }
            let visible = time >= 0.4 && time < 1.2
            if let closed = tracker.observe(at: time, panelCandidate: visible,
                pendingReadSourceTime: pending?.evidence.sourceTime) { groups.append(closed) }
            // One shared lane: a new-panel read cannot start until the slow
            // old-panel request finishes. Subsequent reads return to 25 ms.
            if visible, pending == nil, time - lastSubmission >= 0.2 - 1e-9 {
                pending = (time + 0.025, frame(time, quantity: 5))
                lastSubmission = time
            }
        }
        if let closed = tracker.finish(at: 1.5, reason: "test") { groups.append(closed) }
        #expect(groups.map(\.recognizedQuantity) == [2, 5])
    }

    @Test("A late contradictory shield quantity cannot leave eleven shields in the saved group")
    func lateShieldContradiction() throws {
        func shield(_ time: Double, quantity: Int) -> GearDropFrameEvidence {
            .init(sourceTime: time, stage: .bonus, entries: [
                .init(column: 0, row: 0, item: "Portal Shield", levelState: .notApplicable,
                      level: nil, quantity: quantity, rarity: .common)
            ])
        }
        var tracker = GearDropTracker()
        for (time, quantity) in [(387.157, 1), (387.457, 11), (387.757, 11)] {
            _ = tracker.accept(shield(time, quantity: quantity))
        }
        _ = tracker.observe(at: 388.357, panelCandidate: false)
        #expect(tracker.observe(at: 388.507, panelCandidate: false, pendingReadSourceTime: 388.307) == nil)
        _ = tracker.accept(shield(388.307, quantity: 1))
        let closed = tracker.finish(at: 388.6, reason: "test")
        let group = try #require(closed)
        #expect(group.panels[0].entries.isEmpty && group.panels[0].partial)
    }

    @Test("Conflicts and reading gaps reset agreement instead of unioning rows")
    func conflicts() throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.1))
        _ = tracker.accept(frame(0.2, quantity: 8))
        #expect(tracker.finish(at: 0.3, reason: "test")?.recognizedQuantity == 0)
        let late = 1 + tracker.policy.maximumReadingGap + 0.1
        _ = tracker.accept(frame(1)); _ = tracker.accept(frame(late))
        #expect(tracker.finish(at: late + 0.1, reason: "test")?.recognizedQuantity == 0)
    }

    /// A tester's drop (iPhone 14 Pro, Glyph assistance, English): every row
    /// was read right, but reads came about 0.9 s apart and none confirmed.
    func reportedPanel(_ time: Double, stage: GearDropStage) -> GearDropFrameEvidence {
        func entry(_ column: Int, _ row: Int, _ item: String, _ level: Int?, _ quantity: Int) -> GearDropEntry {
            .init(column: column, row: row, item: item, levelState: level == nil ? .notApplicable : .known,
                  level: level, quantity: quantity)
        }
        let entries = stage == .portal
            ? [entry(0, 0, "Portal Key", nil, 1), entry(1, 0, "Resonator", 7, 4)]
            : [entry(0, 0, "Portal Key", nil, 1), entry(1, 0, "Power Cube", 7, 1),
               entry(0, 1, "XMP Burster", 8, 1), entry(1, 1, "XMP Burster", 7, 3),
               entry(0, 2, "Resonator", 8, 2), entry(1, 2, "Resonator", 7, 3),
               entry(0, 3, "Resonator", 6, 1)]
        return .init(sourceTime: time, stage: stage, entries: entries, unreadableRows: 0)
    }

    @Test("Two agreeing Bonus reads 0.9 s apart confirm the panel")
    func slowBonusReads() throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(reportedPanel(40.240, stage: .bonus))
        _ = tracker.accept(reportedPanel(41.149, stage: .bonus))
        let closed = tracker.finish(at: 41.850, reason: "panelLeft")
        let group = try #require(closed)
        #expect(group.panels.count == 1 && group.panels.first?.partial == false)
        #expect(group.panels.first?.entries.count == 7 && group.recognizedQuantity == 12)
    }

    @Test("Slow phone reads of both panels keep every row until the panel leaves")
    func slowReadsOfReportedDrop() throws {
        var tracker = GearDropTracker()
        // OCR completions as logged, and a second portal read 0.6 s after the
        // first; unread titles say nothing about the rows.
        let reads: [(Double, GearDropStage)] = [(38.113, .unknown), (38.814, .portal), (39.264, .unknown),
                                                (39.414, .portal), (40.240, .bonus), (41.149, .bonus)]
        var pending = reads[...]
        var closed: GearDropSummary?
        // Geometry at 20 Hz: the panel shows until 41.7 s.
        for step in 0..<80 {
            let time = 38.1 + Double(step) * 0.05
            while let read = pending.first, read.0 <= time + 1e-9 {
                let evidence = read.1 == .unknown
                    ? GearDropFrameEvidence(sourceTime: read.0, stage: .unknown)
                    : reportedPanel(read.0, stage: read.1)
                closed = closed ?? tracker.accept(evidence)
                pending = pending.dropFirst()
            }
            closed = closed ?? tracker.observe(at: time, panelCandidate: time < 41.7)
        }
        let group = try #require(closed)
        #expect(group.closeReason == "panelLeft")
        #expect(group.panels.map(\.stage) == [.portal, .bonus])
        #expect(group.panels.map(\.entries.count) == [2, 7])
        // Portal 1 + 4, Bonus 1 + 1 + 1 + 3 + 2 + 3 + 1.
        #expect(group.bothPanelsRead && group.recognizedQuantity == 17)
    }

    @Test("Bonus to portal can close a group without an empty screen")
    func adjacentGroups() throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.1))
        _ = tracker.accept(frame(0.2, stage: .bonus)); _ = tracker.accept(frame(0.3, stage: .bonus))
        let firstValue = tracker.accept(frame(0.4))
        let first = try #require(firstValue)
        #expect(first.groupID == 1 && first.recognizedQuantity == 4)
        _ = tracker.accept(frame(0.5))
        #expect(tracker.finish(at: 0.6, reason: "test")?.groupID == 2)
    }

    @Test("An obscured row is partial even when other quantities agree")
    func incomplete() {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0, unreadable: 1)); _ = tracker.accept(frame(0.1, unreadable: 1))
        #expect(tracker.finish(at: 0.2, reason: "test")?.panels.first?.partial == true)
    }

    @Test("A source gap closes the visual group without claiming completeness")
    func gap() {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0))
        #expect(tracker.observe(at: 2, panelCandidate: true, continuityLost: true)?.closeReason == "continuityLost")
    }

    @Test("Three queued hacks survive the next input and take their groups in order")
    func queue() throws {
        var session = GearDropObservationSession()
        for id in 1...3 { session.enqueue(hackID: id, at: Double(id)) }
        #expect(session.waiting.map(\.hackID) == [1, 2, 3])
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(4)); _ = tracker.accept(frame(4.1, stage: .bonus))
        let groupValue = tracker.finish(at: 4.2, reason: "test")
        let group = try #require(groupValue)
        let attached = session.close(group)
        #expect(attached.hackID == 1 && attached.association == .ordered)
        #expect(session.waiting.map(\.hackID) == [2, 3])
    }

    @Test("A Hacking Bonus page waiting offline extends inactivity but not the absolute limit")
    func serverWait() {
        var session = GearDropObservationSession()
        session.observe(at: 0, hackID: 1, inputVisible: true)
        // Result reading may already have closed; the page's geometry still counts.
        for t in stride(from: 0.5, through: 55, by: 0.5) {
            session.observe(at: t, hackID: 1, inputVisible: false, gameProgressVisible: true)
        }
        #expect(session.waiting.map(\.hackID) == [1])
        for t in stride(from: 55.5, through: 84, by: 0.5) { session.observe(at: t, hackID: 1, inputVisible: false) }
        #expect(session.waiting.map(\.hackID) == [1])
        for t in stride(from: 84.5, through: 86, by: 0.5) { session.observe(at: t, hackID: 1, inputVisible: false) }
        #expect(session.waiting.isEmpty)
        #expect(session.events.last?.reason == "waitTimeout")
    }

    @Test("A read that lost one level does not undo a confirmed panel")
    func lostDetail() throws {
        func weak(_ time: Double) -> GearDropFrameEvidence {
            .init(sourceTime: time, stage: .bonus, entries: [
                GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .unreadable, level: nil, quantity: 2)
            ])
        }
        // A lost level in the middle, and one just before the panel closes.
        var tracker = GearDropTracker()
        for t in [0.0, 0.25, 0.5] { _ = tracker.accept(frame(t, stage: .bonus)) }
        _ = tracker.accept(weak(0.75))
        _ = tracker.accept(frame(1.0, stage: .bonus))
        _ = tracker.accept(weak(1.25))
        let keptValue = tracker.finish(at: 1.4, reason: "test")
        let kept = try #require(keptValue)
        #expect(kept.panels.first?.partial == false)
        #expect(kept.panels.first?.entries.first?.level == 6 && kept.recognizedQuantity == 2)

        // The level was read once; the reads that agree keep the item and
        // quantity, and the level stays unknown rather than guessed.
        var second = GearDropTracker()
        _ = second.accept(frame(0, stage: .bonus))
        _ = second.accept(weak(0.25)); _ = second.accept(weak(0.5))
        let weakenedValue = second.finish(at: 0.6, reason: "test")
        let weakened = try #require(weakenedValue)
        #expect(weakened.panels.first?.entries.first?.levelState == .unreadable)
        #expect(weakened.unidentifiedQuantity == 2 && weakened.recognizedQuantity == 0)
    }

    @Test("A contradicting quantity is uncertain until the confirmed one is read again")
    func conflictResolves() throws {
        var tracker = GearDropTracker()
        _ = tracker.accept(frame(0)); _ = tracker.accept(frame(0.25))
        _ = tracker.accept(frame(0.5, quantity: 8))
        _ = tracker.accept(frame(0.75))
        let resolvedValue = tracker.finish(at: 0.8, reason: "test")
        let resolved = try #require(resolvedValue)
        #expect(resolved.recognizedQuantity == 2 && resolved.panels.first?.partial == false)

        var twice = GearDropTracker()
        for (t, q) in [(0.0, 2), (0.25, 2), (0.5, 8), (0.75, 8)] { _ = twice.accept(frame(t, quantity: q)) }
        let contradictedValue = twice.finish(at: 0.8, reason: "test")
        let contradicted = try #require(contradictedValue)
        #expect(contradicted.recognizedQuantity == 0 && contradicted.panels.first?.partial == true)
    }

    @Test("Missing detail cannot lengthen supporting votes or bridge their gap")
    func missingDetailDoesNotVote() throws {
        func weak(_ time: Double) -> GearDropFrameEvidence {
            .init(sourceTime: time, stage: .portal, entries: [
                GearDropEntry(column: 0, row: 0, item: "XMP Burster", levelState: .unreadable, level: nil, quantity: 2)
            ])
        }
        // Weak reads span the gap between the two supporting reads.
        let late = GearDropTracker.Policy().maximumReadingGap + 0.1
        for supportingTimes in [[0.0, 0.05], [0.0, late]] {
            var tracker = GearDropTracker()
            let times = (supportingTimes + [0.2, 0.3, late / 2]).sorted()
            for time in times {
                _ = tracker.accept(supportingTimes.contains(time) ? frame(time) : weak(time))
            }
            let value = tracker.finish(at: late + 0.1, reason: "test")
            let group = try #require(value)
            #expect(group.panels.first?.entries.first?.item == "XMP Burster")
            #expect(group.panels.first?.entries.first?.levelState == .unreadable)
            #expect(group.recognizedQuantity == 0 && group.unidentifiedQuantity == 2)
        }
    }

    @Test("An expired wait cannot shift its late group onto a later hack")
    func expiredQueueDoesNotShift() throws {
        for explicitExpiry in [false, true] {
            var session = GearDropObservationSession()
            session.enqueue(hackID: 1, at: 0)
            session.enqueue(hackID: 2, at: 110)
            if explicitExpiry { session.expire(at: 121) }
            var tracker = GearDropTracker()
            _ = tracker.accept(frame(122)); _ = tracker.accept(frame(122.2))
            _ = tracker.accept(frame(123, stage: .bonus)); _ = tracker.accept(frame(123.2, stage: .bonus))
            let value = tracker.finish(at: 125, reason: "panelLeft")
            let group = try #require(value)
            let attached = session.close(group)
            #expect(attached.hackID == nil && attached.association == .uncertainContinuity)
            // The group still uses up the oldest wait, so hack 2 cannot later
            // take hack 1's or its own group by order.
            #expect(session.waiting.isEmpty)
            // An empty queue alone does not restore order within the quiet period.
            session.expire(at: 150)
            session.enqueue(hackID: 3, at: 151)
            let late = GearDropSummary(groupID: 2, startedAt: 152, closedAt: 153,
                closeReason: "panelLeft", hackID: nil, association: .unassociated, panels: group.panels)
            #expect(session.close(late).hackID == nil)
        }
    }

    @Test("A gap retires ownership before closing the group and rejects pre-gap evidence")
    func gapOwnership() throws {
        var session = GearDropObservationSession()
        var tracker = GearDropTracker()
        session.enqueue(hackID: 1, at: 0)
        session.prepareFrame(at: 0, continuityLost: false)
        for time in [0.0, 0.2] { _ = tracker.accept(frame(time)) }
        for time in [0.4, 0.6] { _ = tracker.accept(frame(time, stage: .bonus)) }
        session.prepareFrame(at: 0.6, continuityLost: false)
        let lost = session.prepareFrame(at: 2, continuityLost: true)
        #expect(lost)
        let value = tracker.loseContinuity(at: 2)
        let group = try #require(value)
        #expect(!group.bothPanelsRead && group.panels.allSatisfy(\.partial))
        let unattached = session.close(group)
        #expect(unattached.hackID == nil && unattached.association == .uncertainContinuity)
        _ = tracker.accept(frame(0.8))
        #expect(!tracker.isObserving)
        _ = tracker.accept(frame(2.1, stage: .bonus, quantity: 8))
        _ = tracker.accept(frame(2.3, stage: .bonus, quantity: 8))
        let fresh = tracker.finish(at: 2.4, reason: "panelLeft")
        #expect(fresh?.panels.count == 1 && fresh?.recognizedQuantity == 8)

        var empty = GearDropTracker()
        _ = empty.loseContinuity(at: 2)
        _ = empty.accept(frame(0.8))
        #expect(!empty.isObserving)
    }

    @Test("Evidence budgets preserve both untouched panels and a briefly tapped Bonus panel")
    func evidenceBudgets() {
        for bonusDuration in [0.4, 1.8] {
            var schedule = GearEvidenceSchedule()
            var saved: [(GearDropStage, Double)] = []
            for index in 0..<Int((1.8 + bonusDuration) / 0.2) {
                let time = Double(index) * 0.2
                let stage: GearDropStage = index < 9 ? .portal : .bonus
                if schedule.shouldSave(stage: stage, at: time) {
                    schedule.didEnqueue(stage: stage, at: time)
                    saved.append((stage, time))
                }
            }
            #expect(saved.contains { $0.0 == .portal })
            #expect(saved.contains { $0.0 == .bonus && abs($0.1 - 1.8) < 1e-9 })
            #expect(saved.count <= 8)
            for stage in [GearDropStage.portal, .bonus] {
                let times = saved.filter { $0.0 == stage }.map { $0.1 }
                #expect(times.count <= 4)
                for (first, next) in zip(times, times.dropFirst()) { #expect(next - first >= 0.5) }
            }
        }
        var schedule = GearEvidenceSchedule()
        for time in [0.0, 0.5, 1.0, 1.5] { schedule.didEnqueue(stage: .portal, at: time) }
        #expect(!schedule.shouldSave(stage: .portal, at: 2))
        #expect(schedule.shouldSave(stage: .bonus, at: 1.6))
        // A writer-busy attempt has not called didEnqueue, so retry immediately.
        #expect(schedule.shouldSave(stage: .bonus, at: 1.7))
    }

    @Test("A no-Bonus group goes to a 0% hack but not to one whose result promised bonus items")
    func groupsWithoutBonus() throws {
        func group(bonus: Bool, at time: Double) throws -> GearDropSummary {
            var tracker = GearDropTracker()
            _ = tracker.accept(frame(time)); _ = tracker.accept(frame(time + 0.25))
            if bonus { _ = tracker.accept(frame(time + 0.5, stage: .bonus)); _ = tracker.accept(frame(time + 0.75, stage: .bonus)) }
            let closed = tracker.finish(at: time + 1, reason: "test")
            return try #require(closed)
        }
        func result(hack: Int, bonus: Int) -> HackResult {
            var result = HackResult(context: ResultReadContext(sessionID: .init(rawValue: 1), hackID: hack, glyphs: ["xm"]),
                                    outcomes: [.unknown], outcomeTimes: [nil])
            result.finalHackingBonus = bonus
            return result
        }
        var session = GearDropObservationSession()
        session.enqueue(hackID: 7, at: 0); session.accept(result(hack: 7, bonus: 0))
        session.enqueue(hackID: 8, at: 1); session.accept(result(hack: 8, bonus: 120))
        let zero = session.close(try group(bonus: false, at: 2))
        #expect(zero.hackID == 7 && zero.association == .orderedWithoutBonus)
        // An ordinary hack's group before hack 8's own leaves hack 8 waiting.
        let ordinary = session.close(try group(bonus: false, at: 4))
        #expect(ordinary.hackID == nil && ordinary.association == .bonusExpected)
        let own = session.close(try group(bonus: true, at: 6))
        #expect(own.hackID == 8 && own.association == .ordered && session.waiting.isEmpty)
        let stray = session.close(try group(bonus: true, at: 8))
        #expect(stray.association == .noWaitingHack)
    }

    @Test("Gear uses one lane, yields during input, and leaves disabled scheduling unchanged")
    func schedule() throws {
        var schedule = GameTextSchedule()
        let headerValue = schedule.take(at: 0, panelCandidate: false, resultEligible: false,
                                                gearCandidate: true, headerPriority: true)
        let header = try #require(headerValue)
        #expect(header.mode == .header)
        #expect(schedule.take(at: 1, panelCandidate: false, resultEligible: false, gearCandidate: true) == nil)
        schedule.finish(header)
        let gearValue = schedule.take(at: 1, panelCandidate: false, resultEligible: false, gearCandidate: true)
        let gear = try #require(gearValue)
        #expect(gear.mode == .gear)
        schedule.finish(gear, panelPresent: true)
        // The header waits for the panel rather than take the lane between reads.
        #expect(schedule.take(at: 1.11, panelCandidate: false, resultEligible: false, gearCandidate: true) == nil)
        #expect(schedule.take(at: 1.2, panelCandidate: false, resultEligible: false, gearCandidate: true)?.mode == .gear)
    }

    @Test("A longer gear interval spaces panel reads, and a failing panel still backs off to a second")
    func gearInterval() throws {
        var schedule = GameTextSchedule()
        func take(_ time: Double) -> GameTextSchedule.Request? {
            schedule.take(at: time, panelCandidate: false, resultEligible: false, gearCandidate: true,
                          readsHeader: false, gearInterval: 0.4)
        }
        var reads: [Double] = []
        for step in 0...40 {
            let time = Double(step) * 0.05
            if let request = take(time) { reads.append(time); schedule.finish(request, panelPresent: true) }
        }
        #expect(reads.count == 6, "every 0.4 s over 2 s: \(reads)")
        var failing = GameTextSchedule(), misses: [Double] = []
        for step in 0...80 {
            let time = Double(step) * 0.05
            if let request = failing.take(at: time, panelCandidate: false, resultEligible: false, gearCandidate: true,
                                          readsHeader: false, gearInterval: 0.4) {
                misses.append(time); failing.finish(request, panelPresent: false)
            }
        }
        #expect(misses.prefix(3).map { ($0 * 100).rounded() } == [0, 40, 80])
        #expect(zip(misses.dropFirst(3), misses.dropFirst(2)).allSatisfy { $0 - $1 >= 0.998 })
    }

    @Test("While a panel shows, no header read takes the lane between gear reads")
    func headerWaitsForPanel() throws {
        var schedule = GameTextSchedule()
        var time = 0.0
        var modes: [GameTextSchedule.Mode] = []
        // A panel at 20 Hz for 2 s, each gear read finishing within one frame.
        while time < 2 {
            if let request = schedule.take(at: time, panelCandidate: false, resultEligible: false, gearCandidate: true) {
                modes.append(request.mode)
                schedule.finish(request, panelPresent: true)
            }
            time += 0.05
        }
        #expect(modes.count == 10 && modes.allSatisfy { $0 == .gear })
        // Once the panel leaves, the header has the lane again.
        #expect(schedule.take(at: 2, panelCandidate: false, resultEligible: false)?.mode == .header)
    }

    @Test("A false panel candidate that backed off after three misses leaves the header its reads")
    func headerReadsDuringGearBackOff() throws {
        var schedule = GameTextSchedule()
        for time in [0.0, 0.2, 0.4] {
            let taken = schedule.take(at: time, panelCandidate: false, resultEligible: false, gearCandidate: true)
            let gear = try #require(taken)
            #expect(gear.mode == .gear)
            schedule.finish(gear, panelPresent: false)
        }
        // Gear now reads once a second; the header reads between.
        let headerValue = schedule.take(at: 0.6, panelCandidate: false, resultEligible: false, gearCandidate: true)
        let header = try #require(headerValue)
        #expect(header.mode == .header)
        schedule.finish(header)
        #expect(schedule.take(at: 0.75, panelCandidate: false, resultEligible: false,
                              gearCandidate: true)?.mode == .header)
        // Two misses are not yet a back-off: the header still waits.
        var twoMisses = GameTextSchedule()
        for time in [0.0, 0.2] {
            let taken = twoMisses.take(at: time, panelCandidate: false, resultEligible: false, gearCandidate: true)
            twoMisses.finish(try #require(taken), panelPresent: false)
        }
        #expect(twoMisses.take(at: 0.3, panelCandidate: false, resultEligible: false, gearCandidate: true) == nil)
    }

    /// A panel shown for `duration` seconds, sampled every `interval`, with each
    /// panel read taking `latency`: the group that closes, if any.
    func shortPanel(duration: Double, interval: Double, latency: Double) -> GearDropSummary? {
        var schedule = GameTextSchedule()
        var tracker = GearDropTracker()
        var pending: GameTextSchedule.Request?
        var closed: GearDropSummary?
        for step in 0..<Int((duration + 1) / interval) {
            let time = Double(step) * interval
            let visible = time < duration
            if let request = pending, request.sourceTime + latency <= time + 1e-9 {
                schedule.finish(request, panelPresent: true)
                closed = closed ?? tracker.accept(frame(request.sourceTime))
                pending = nil
            }
            closed = closed ?? tracker.observe(at: time, panelCandidate: visible)
            if visible, let request = schedule.take(at: time, panelCandidate: false, resultEligible: false,
                                                    gearCandidate: true, readsHeader: false) {
                pending = request
            }
        }
        return closed
    }

    @Test("At the capture's 20 Hz a tapped 0.4-second panel is read while each read takes up to 0.25 s",
          arguments: [0.05, 0.15, 0.25])
    func shortPanelAtCaptureRate(latency: Double) throws {
        let group = try #require(shortPanel(duration: 0.4, interval: 0.05, latency: latency))
        #expect(group.panels.flatMap(\.entries).map(\.quantity) == [2], "latency \(latency)")
    }

    /// The group closes 0.15 s after the panel leaves, so the second read must
    /// finish by then: slow reads lose short panels at any frame rate.
    @Test("Reads of 0.35 s keep a 0.6-second panel at 20 Hz but lose a tapped 0.4-second one")
    func shortPanelSlowReads() {
        #expect(shortPanel(duration: 0.6, interval: 0.05, latency: 0.35)?.panels.flatMap(\.entries).count == 1)
        #expect(shortPanel(duration: 0.4, interval: 0.05, latency: 0.35)?.panels.flatMap(\.entries).isEmpty != false)
    }

    @Test("Without header reading, the lane reads only panels")
    func gearOnlySchedule() throws {
        var schedule = GameTextSchedule()
        #expect(schedule.take(at: 0, panelCandidate: false, resultEligible: false, readsHeader: false) == nil)
        let firstValue = schedule.take(at: 0.1, panelCandidate: false, resultEligible: false,
                                       gearCandidate: true, readsHeader: false)
        let first = try #require(firstValue)
        #expect(first.mode == .gear)
        schedule.finish(first, panelPresent: true)
        // Between gear reads nothing else is submitted.
        #expect(schedule.take(at: 0.2, panelCandidate: false, resultEligible: false,
                              gearCandidate: true, readsHeader: false) == nil)
        #expect(schedule.take(at: 0.3, panelCandidate: false, resultEligible: false,
                              gearCandidate: true, readsHeader: false)?.mode == .gear)
    }

    @Test("Order is restored once the queue empties and the quiet period passes")
    func orderRestored() throws {
        func group(at time: Double) throws -> GearDropSummary {
            var tracker = GearDropTracker()
            _ = tracker.accept(frame(time)); _ = tracker.accept(frame(time + 0.25))
            _ = tracker.accept(frame(time + 0.5, stage: .bonus)); _ = tracker.accept(frame(time + 0.75, stage: .bonus))
            let closed = tracker.finish(at: time + 1, reason: "panelLeft")
            return try #require(closed)
        }
        var session = GearDropObservationSession()
        var now = 0.0
        func frames(until end: Double, hack: Int = 0, input: Bool = false) {
            while now < end { now += 0.5; session.observe(at: now, hackID: hack, inputVisible: input) }
        }
        // An abandoned hack: its wait expires without any panels.
        frames(until: 1, hack: 1, input: true); frames(until: 40)
        #expect(session.waiting.isEmpty && session.isAssociationUncertain)
        frames(until: 75)
        #expect(!session.isAssociationUncertain)
        // The next hack's drops attach to it as usual.
        frames(until: 80, hack: 2, input: true); frames(until: 85)
        let attached = session.close(try group(at: now))
        #expect(attached.hackID == 2 && attached.association == .ordered)
    }

    @Test("A still screen's missing frames are not a break; the caller decides")
    func stillScreen() {
        var session = GearDropObservationSession()
        session.enqueue(hackID: 1, at: 0)
        let lost1 = session.prepareFrame(at: 0, continuityLost: false)
        #expect(!lost1)
        // Two seconds without new frames, as when nothing on screen changes.
        let lost2 = session.prepareFrame(at: 2, continuityLost: false)
        #expect(!lost2)
        #expect(session.waiting.map(\.hackID) == [1] && !session.isAssociationUncertain)
        // A timestamp going backwards is a break whatever the caller says.
        let lost3 = session.prepareFrame(at: 1, continuityLost: false)
        #expect(lost3)
        #expect(session.waiting.isEmpty && session.isAssociationUncertain)
        // With nobody waiting, an interruption cannot misplace a group.
        var idle = GearDropObservationSession()
        let lost4 = idle.prepareFrame(at: 5, continuityLost: true)
        #expect(lost4)
        #expect(!idle.isAssociationUncertain)
    }

    @Test("An effect line is recorded, not read as an unreadable item row")
    func effectLine() {
        // Tester report: a portal panel showed "ITO EN (+) applied." under its
        // title and was marked partly read.
        let value = parser.read(lines: [line("Test location", x: 0.3, y: 0.31),
            line("ITO EN (+) applied.", x: 0.28, y: 0.34, width: 0.44),
            line("/// x1 Portal Shield", y: 0.386), line("L8 x2 Resonator", x: 0.58, y: 0.386)], bounds: bounds, at: 1)
        #expect(value.stage == .portal && value.unreadableRows == 0)
        #expect(value.effects == ["ITO EN (+)"])
        #expect(value.entries.map(\.item) == ["Portal Shield", "Resonator"])
        #expect(GearDropTextParser.effect(from: "ITO EN (-) applied") == "ITO EN (-)")
        #expect(GearDropTextParser.effect(from: "L8 x2 Resonator") == nil)
        var tracker = GearDropTracker()
        _ = tracker.accept(value)
        _ = tracker.accept(parser.read(lines: [line("Test location", x: 0.3, y: 0.31),
            line("ITO EN (+) applied.", x: 0.28, y: 0.34, width: 0.44),
            line("/// x1 Portal Shield", y: 0.386), line("L8 x2 Resonator", x: 0.58, y: 0.386)], bounds: bounds, at: 1.25))
        let panel = tracker.finish(at: 1.4, reason: "test")?.panels.first
        #expect(panel?.effects == ["ITO EN (+)"] && panel?.partial == false)
    }

    @Test("Hypercube and Force Amp are known items without levels")
    func testerItems() {
        let hypercube = parser.parseEntry("/// x1 Hypercube", row: 0, column: 0)
        #expect(hypercube?.item == "Hypercube" && hypercube?.levelState == .notApplicable)
        let forceAmp = parser.parseEntry("/// x1 Force Amp", row: 0, column: 0)
        #expect(forceAmp?.item == "Force Amp" && forceAmp?.levelState == .notApplicable)
    }

    @Test("The researched item vocabulary preserves levels and transmuter signs")
    func itemVocabulary() {
        for name in ["Resonator", "XMP Burster", "Power Cube", "Ultra Strike"] {
            for level in 1...8 {
                let value = parser.parseEntry("L\(level) x2 \(name)", row: 0, column: 0)
                #expect(value?.item == name && value?.level == level && value?.quantity == 2)
            }
        }
        for name in ["Portal Key", "Portal Shield", "Turret", "Link Amp", "Multi-Hack", "JARVIS Virus",
                     "Heat Sink", "Kinetic Capsule", "Hypercube", "Force Amp", "ADA Refactor", "Aegis Shield",
                     "SoftBank Ultra Link", "Capsule", "Media", "ITO EN Transmuter (+)", "ITO EN Transmuter (-)"] {
            let value = parser.parseEntry("III x2 \(name)", row: 0, column: 0)
            #expect(value?.item == name && value?.levelState == .notApplicable && value?.quantity == 2)
        }
        #expect(parser.parseEntry("x1 ITO EN Transmuter (−)", row: 0, column: 0)?.item == "ITO EN Transmuter (-)")
        for name in ["ITO EN Tr...", "ITO EN Transmuter", "ITO EN Transmuter ()", "Unknown Media Title",
                     "Quantum Capsule", "Fracker", "Key Locker"] {
            let value = parser.parseEntry("x1 \(name)", row: 0, column: 0)
            #expect(value?.item == nil && value?.quantity == 1)
        }
    }

    @Test("Only known, confident effect labels above the items are excluded from rows")
    func effectGrammar() {
        for (text, expected) in [("ITO EN Transmuter (+) applied.", "ITO EN (+)"),
                                 ("ITO EN Transmuter (−) applied.", "ITO EN (-)"),
                                 ("ito en (-) APPLIED", "ITO EN (-)")] {
            #expect(GearDropTextParser.effect(from: text) == expected)
        }
        for text in ["Secret location applied.", "ITO EN applied.", "ITO EN (+/-) applied.",
                     "ITO EN (+) applied. extra", "ITO EN (+) applled."] {
            #expect(GearDropTextParser.effect(from: text) == nil)
        }
        for (text, confidence, y) in [("Secret location applied.", 1.0, 0.34),
                                      ("ITO EN (+) applied.", 0.4, 0.34),
                                      ("ITO EN (+) applied.", 1.0, 0.42)] {
            let evidence = parser.read(lines: [line("Reference panel", x: 0.3, y: 0.31),
                line(text, x: 0.28, y: y, width: 0.44, confidence: confidence),
                line("x1 Portal Shield", y: 0.386)], bounds: bounds, at: 0)
            #expect(evidence.effects == nil && evidence.unreadableRows > 0)
        }
    }

    @Test("Six rows fit below an effect and missing the label never duplicates items")
    func effectRows() {
        let tall = GearDropPanelBounds(top: 0.29, bottom: 0.61)
        var lines = [line("Reference panel", x: 0.3, y: 0.31)]
        for row in 1...6 {
            for column in 0...1 {
                lines.append(line("L8 x2 Resonator", x: column == 0 ? 0.1 : 0.58,
                                  y: 0.35 + Double(row) * 0.036))
            }
        }
        let plain = parser.read(lines: lines, bounds: tall, at: 0.2)
        lines.append(line("ITO EN (+) applied.", x: 0.28, y: 0.34, width: 0.44))
        let withEffect = parser.read(lines: lines, bounds: tall, at: 0)
        #expect(withEffect.entries.count == 12 && withEffect.unreadableRows == 0)
        #expect(plain.entries == withEffect.entries)
        var tracker = GearDropTracker()
        _ = tracker.accept(withEffect)
        _ = tracker.accept(plain)
        _ = tracker.accept(parser.read(lines: lines, bounds: tall, at: 0.3))
        let group = tracker.finish(at: 0.4, reason: "test")
        #expect(group?.recognizedQuantity == 24 && group?.panels.first?.partial == false)
    }

    @Test("Effects require agreement, keep contradictions uncertain, and reset for each panel")
    func effectAgreement() {
        func reading(_ time: Double, _ effect: String?, stage: GearDropStage = .portal) -> GearDropFrameEvidence {
            .init(sourceTime: time, stage: stage, entries: frame(time).entries, effects: effect.map { [$0] })
        }
        let plus = "ITO EN (+)", minus = "ITO EN (-)"
        let late = GearDropTracker.Policy().maximumReadingGap + 0.1
        for reads: [(Double, String?)] in [[(0, plus), (0.2, nil)], [(0, plus), (0.05, plus), (0.2, nil)],
                                          [(0, plus), (late, plus)], [(0, plus), (0.2, minus)],
                                          [(0, plus), (0.2, plus), (0.3, minus), (0.5, minus)]] {
            var tracker = GearDropTracker()
            for (time, effect) in reads { _ = tracker.accept(reading(time, effect)) }
            let panel = tracker.finish(at: late + 0.1, reason: "test")?.panels.first
            #expect(panel?.effects == nil && panel?.partial == true)
        }
        var tracker = GearDropTracker()
        _ = tracker.accept(reading(0, plus)); _ = tracker.accept(reading(0.2, plus))
        _ = tracker.accept(reading(0.3, nil))
        _ = tracker.accept(reading(0.4, nil, stage: .bonus)); _ = tracker.accept(reading(0.6, nil, stage: .bonus))
        let group = tracker.finish(at: 0.7, reason: "test")
        #expect(group?.panels.first?.effects == [plus])
        #expect(group?.panels.last?.effects == nil && group?.bothPanelsRead == true)
        #expect(group?.recognizedQuantity == 4)
    }

    @Test("Effects round-trip in logs and older panels still decode")
    func effectCoding() throws {
        let old = Data(#"{"stage":"portal","entries":[],"partial":true}"#.utf8)
        let decoded = try JSONDecoder().decode(GearDropSummary.Panel.self, from: old)
        #expect(decoded.effects == nil)
        let evidence = GearDropFrameEvidence(sourceTime: 1, stage: .bonus, effects: ["ITO EN (-)"])
        let data = try JSONEncoder().encode(evidence)
        #expect(try JSONDecoder().decode(GearDropFrameEvidence.self, from: data) == evidence)
        let oldEvidence = Data(#"{"sourceTime":1,"stage":"bonus","entries":[],"unreadableRows":0}"#.utf8)
        #expect(try JSONDecoder().decode(GearDropFrameEvidence.self, from: oldEvidence).effects == nil)
    }
}
