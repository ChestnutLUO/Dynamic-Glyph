import Foundation
import Testing
@testable import GlyphRecognition

/// A gear read that finds no panel title but whose body is plainly a drop
/// panel (the effect line, or rows naming known items) is a panel with an
/// unread title, not a miss. In the 2026-10-28 session a portal panel with a
/// CJK-only name was read as no panel, and those reads backed off the Bonus
/// panel that replaced it in the same place. Entries here are derived from
/// that session's logged rows; no text from it is used.
@Suite("Gear panels with an unread title")
struct GearUntitledPanelTests {
    let parser = GearDropTextParser()
    let bounds = GearDropPanelBounds(top: 0.29, bottom: 0.46)
    func line(_ text: String, x: Double = 0.1, y: Double = 0.35, width: Double = 0.35,
              confidence: Double = 1) -> ResultTextLine {
        ResultTextLine(text: text, confidence: confidence, x: x, y: y, width: width, height: 0.014)
    }
    var effect: ResultTextLine { line("ITO EN (+) applied.", x: 0.3, y: 0.34) }
    var rows: [ResultTextLine] { [line("L6 x1 Power Cube", y: 0.386), line("L6 x1 Resonator", x: 0.58, y: 0.386)] }

    @Test("The body shows a panel: an effect line or a known item, with no title read")
    func untitledBodies() {
        let cases: [([ResultTextLine], Bool, String)] = [
            ([effect] + rows, true, "effect and rows, no title line"),
            ([effect], true, "effect line alone"),
            (rows, true, "known rows alone"),
            ([line("Somewhere", x: 0.3, y: 0.31), line("Elsewhere", x: 0.3, y: 0.315)] + rows, true,
             "two title lines are ambiguous, the rows are not"),
            ([line("Bonus items:", x: 0.3, y: 0.31, confidence: 0.3)] + rows, true, "a title under the floor"),
            ([line("Bonvs items:", x: 0.3, y: 0.31)] + rows, true, "a near miss of the Bonus title"),
        ]
        for (lines, expected, label) in cases {
            #expect(parser.read(lines: lines, bounds: bounds, at: 1).stage == .unknown, "\(label)")
            #expect(parser.showsUntitledPanel(lines: lines, bounds: bounds, at: 1) == expected, "\(label)")
        }
    }

    @Test("Text that shows no panel stays a miss: nothing, unknown names, low confidence, or a stage was read")
    func notUntitled() {
        let cases: [([ResultTextLine], String)] = [
            ([], "nothing read"),
            ([line("x2 Something new", y: 0.386)], "a row naming no known item"),
            ([line("L6 x1 Resonator", y: 0.386, confidence: 0.2)], "a row under the line floor"),
            ([line("ITO EN (+) applied.", x: 0.3, y: 0.34, confidence: 0.4)], "an effect under the title floor"),
            ([line("Hello agent", y: 0.386), line("Map text", x: 0.58, y: 0.42)], "map or message text"),
            ([line("Bounty Claimed", x: 0.3, y: 0.31)] + rows, "an excluded Bounty panel"),
            ([line("奖励物品:", x: 0.3, y: 0.31)] + rows, "another language's Bonus title"),
            ([line("Test location", x: 0.3, y: 0.31)] + rows, "a titled portal panel"),
            ([line("Bonus items:", x: 0.3, y: 0.31)] + rows, "a titled Bonus panel"),
        ]
        for (lines, label) in cases {
            #expect(!parser.showsUntitledPanel(lines: lines, bounds: bounds, at: 1), "\(label)")
        }
        // Nothing of an untitled panel is ever stored: its read has no rows.
        let untitled = parser.read(lines: [effect] + rows, bounds: bounds, at: 1)
        #expect(untitled.entries.isEmpty && untitled.effects == nil)
    }

    // MARK: - Pacing

    static let constrainedMinimum = 0.2, constrainedGear = 0.4
    static let panelPace = GameTextSchedule.Pace(minimumInterval: 0.1, gearInterval: 0.2)

    func take(_ schedule: inout GameTextSchedule, at time: Double, panel: Bool, constrained: Bool,
              settled: Bool = false) -> GameTextSchedule.Request? {
        schedule.take(at: time, panelCandidate: false, resultEligible: false,
                      minimumInterval: constrained ? Self.constrainedMinimum : 0.1, gearCandidate: panel,
                      readsHeader: false, gearInterval: constrained ? Self.constrainedGear : 0.2,
                      gearPanelPace: constrained && !settled ? Self.panelPace : nil)
    }

    @Test("Untitled reads never back the panel off; reads that show no panel still do")
    func backOff() {
        for untitled in [true, false] {
            var schedule = GameTextSchedule()
            var reads: [Int] = []
            for step in 0..<20 {
                let time = Double(step) / 10
                if let request = take(&schedule, at: time, panel: true, constrained: false) {
                    reads.append(step)
                    schedule.finish(request, panelPresent: false, untitledPanel: untitled)
                }
            }
            if untitled {
                #expect(reads == Array(stride(from: 0, to: 20, by: 2)), "every 0.2 s: \(reads)")
            } else {
                // Three misses, then at least a second apart, as before.
                #expect(reads == [0, 2, 4, 14], "\(reads)")
            }
        }
    }

    @Test("An untitled read is no panel read: it gives no panel pace and keeps earlier misses")
    func untitledIsNoPanel() throws {
        var schedule = GameTextSchedule()
        // Two plain misses, an untitled read, then one more miss backs off.
        for (time, untitled) in [(0.0, false), (0.4, false), (0.8, true), (1.2, false)] {
            let request = try #require(take(&schedule, at: time, panel: true, constrained: true))
            schedule.finish(request, panelPresent: false, untitledPanel: untitled)
            #expect(!schedule.readsGearPanel)
        }
        #expect(take(&schedule, at: 1.6, panel: true, constrained: true) == nil, "backed off after three misses")
        #expect(take(&schedule, at: 2.2, panel: true, constrained: true)?.mode == .gear)
    }

    struct Shown {
        let stage: GearDropStage
        let from: Double
        let until: Double
        let entries: [GearDropEntry]
    }

    static func entry(_ column: Int, _ row: Int, _ item: String, level: Int, _ quantity: Int) -> GearDropEntry {
        GearDropEntry(column: column, row: row, item: item, levelState: .known, level: level, quantity: quantity)
    }

    /// Constrained frames every 0.1 s; a read finishes `latency` after it
    /// starts and is consumed on the first frame after that, as on the
    /// phone. A portal panel read as `portalRead` is replaced in the same
    /// place by its Bonus panel.
    func play(portalRead: (Double) -> GearDropFrameEvidence, untitled: Bool, bonusFrom: Double,
              bonusUntil: Double, bonus: [GearDropEntry], latency: Double)
        -> (bonusReads: [Double], groups: [GearDropSummary]) {
        var schedule = GameTextSchedule(), tracker = GearDropTracker()
        var pending: (request: GameTextSchedule.Request, evidence: GearDropFrameEvidence, done: Double)?
        var bonusReads: [Double] = [], groups: [GearDropSummary] = []
        for step in 0...Int(((bonusUntil + 1) * 10).rounded()) {
            let time = Double(step) / 10
            if let read = pending, time >= read.done - 1e-9 {
                let panel = read.evidence.stage == .portal || read.evidence.stage == .bonus
                schedule.finish(read.request, panelPresent: panel,
                                untitledPanel: read.evidence.stage == .unknown && untitled)
                if let closed = tracker.accept(read.evidence) { groups.append(closed) }
                pending = nil
            }
            let shown = time < bonusUntil - 1e-9
            if let closed = tracker.observe(at: time, panelCandidate: shown,
                                            pendingReadSourceTime: pending?.evidence.sourceTime) {
                groups.append(closed)
            }
            guard let request = take(&schedule, at: time, panel: shown, constrained: true,
                                     settled: tracker.currentPanelSettled) else { continue }
            let evidence: GearDropFrameEvidence
            if time >= bonusFrom - 1e-9 {
                bonusReads.append(time)
                evidence = GearDropFrameEvidence(sourceTime: time, stage: .bonus, entries: bonus, effects: ["ITO EN (-)"])
            } else {
                evidence = portalRead(time)
            }
            pending = (request, evidence, time + latency)
        }
        if let closed = tracker.finish(at: bonusUntil + 1, reason: "test") { groups.append(closed) }
        return (bonusReads, groups)
    }

    @Test("Constrained, the Bonus panel after an untitled portal panel is read on time and kept")
    func bonusAfterUntitledPortal() throws {
        // As 2026-10-28 hack 3, with a slower read: a portal panel whose title
        // is never read, then its Bonus panel for 0.7 s in the same place.
        let bonus = [Self.entry(0, 0, "Power Cube", level: 8, 1), Self.entry(1, 0, "XMP Burster", level: 8, 6)]
        let unread = { (time: Double) in GearDropFrameEvidence(sourceTime: time, stage: .unknown) }
        let after = play(portalRead: unread, untitled: true, bonusFrom: 1.3, bonusUntil: 2.0, bonus: bonus,
                         latency: 0.3)
        let first = try #require(after.bonusReads.first, "the Bonus panel was never read")
        // The panel's normal constrained cadence, plus the frame it waits for.
        #expect(first - 1.3 <= Self.constrainedGear + 1e-9, "first Bonus read \(first - 1.3) s after it came")
        #expect(after.groups.count == 1)
        let stored = after.groups.first?.panels.first { $0.stage == .bonus }
        #expect(stored?.entries.map(\.quantity) == [1, 6], "\(String(describing: stored))")
        #expect(stored?.partial == false)
        #expect(after.groups.first?.panels.contains { $0.stage == .portal } == false,
                "nothing of the untitled panel is stored")
    }

    @Test("Reads that show no panel at all still back off the next panel, as before")
    func plainMissesStillBackOff() throws {
        let bonus = [Self.entry(0, 0, "Power Cube", level: 8, 1)]
        let unread = { (time: Double) in GearDropFrameEvidence(sourceTime: time, stage: .unknown) }
        let before = play(portalRead: unread, untitled: false, bonusFrom: 1.3, bonusUntil: 2.0, bonus: bonus,
                          latency: 0.3)
        let first = try #require(before.bonusReads.first)
        #expect(first >= 1.8 - 1e-9, "three misses back off to a second: \(first)")
    }
}
