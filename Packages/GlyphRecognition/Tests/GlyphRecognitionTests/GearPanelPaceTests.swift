import Foundation
import Testing
@testable import GlyphRecognition

/// A constrained lane (Low Power Mode, a hot phone) reads a gear panel at the
/// normal pace once a read has found it there, until its rows are confirmed,
/// so a short portal panel gets the two agreeing reads its rows need. The spacings are the app's:
/// `GameHeaderReader`'s 0.1-s lane and 0.2-s gear interval, both doubled when
/// constrained. Frames come every 0.1 s, about the constrained analysis pace
/// (0.099 s), on a grid that keeps the comparisons clear of rounding.
@Suite("Gear panel pace when constrained")
struct GearPanelPaceTests {
    static let constrainedMinimum = 0.2, constrainedGear = 0.4
    static let panelPace = GameTextSchedule.Pace(minimumInterval: 0.1, gearInterval: 0.2)
    static let frameInterval = 0.1

    func take(_ schedule: inout GameTextSchedule, at time: Double, panel: Bool,
              paced: Bool = true) -> GameTextSchedule.Request? {
        schedule.take(at: time, panelCandidate: false, resultEligible: false,
                      minimumInterval: Self.constrainedMinimum, gearCandidate: panel, readsHeader: false,
                      gearInterval: Self.constrainedGear, gearPanelPace: paced ? Self.panelPace : nil)
    }

    @Test("A panel a read has found keeps the normal pace; once it leaves, the slow pace returns")
    func paceFollowsThePanel() throws {
        var schedule = GameTextSchedule()
        var reads: [Double] = []
        // Panel from 0 to 1.2 s, nothing until 1.5 s, then a panel nobody reads
        // as one (a cooldown banner, say) until 3 s.
        for step in 0..<31 {
            let time = Double(step) * Self.frameInterval
            let panel = time < 1.2 || time >= 1.5
            if let request = take(&schedule, at: time, panel: panel) {
                reads.append(time)
                schedule.finish(request, panelPresent: time < 1.2)
            }
        }
        let first = reads.filter { $0 < 1.2 }
        #expect(first.count == 6, "every 0.2 s on the panel: \(first)")
        #expect(zip(first.dropFirst(), first).allSatisfy { $0 - $1 < 0.3 })
        let banner = reads.filter { $0 >= 1.5 }
        #expect(banner.count >= 2)
        // Not found as a panel: the slow pace, as before.
        #expect(zip(banner.dropFirst(), banner).allSatisfy { $0 - $1 >= Self.constrainedGear - 0.002 },
                "\(banner)")
        #expect(!schedule.readsGearPanel)
    }

    @Test("Without a panel pace the constrained lane reads a panel every 0.4 s, as before")
    func unpacedIsUnchanged() {
        var schedule = GameTextSchedule()
        var reads: [Double] = []
        for step in 0..<13 {
            let time = Double(step) * Self.frameInterval
            if let request = take(&schedule, at: time, panel: true, paced: false) {
                reads.append(time); schedule.finish(request, panelPresent: true)
            }
        }
        #expect(zip(reads.dropFirst(), reads).allSatisfy { $0 - $1 >= Self.constrainedGear - 0.002 }, "\(reads)")
    }

    @Test("A panel that leaves while its read runs lends nothing to the next panel")
    func departureDuringRead() throws {
        var schedule = GameTextSchedule()
        let request = try #require(take(&schedule, at: 0, panel: true))
        #expect(take(&schedule, at: 0.1, panel: false) == nil, "the lane is busy")
        schedule.finish(request, panelPresent: true)
        #expect(!schedule.readsGearPanel)
        // A new panel: its first read waits the slow interval from the last one.
        #expect(take(&schedule, at: 0.2, panel: true) == nil)
        #expect(take(&schedule, at: 0.3, panel: true) == nil)
        #expect(take(&schedule, at: 0.4, panel: true)?.mode == .gear)
    }

    @Test("A read that finds no panel title returns the lane to the slow pace")
    func unreadTitle() throws {
        var schedule = GameTextSchedule()
        let found = try #require(take(&schedule, at: 0, panel: true))
        schedule.finish(found, panelPresent: true)
        let unread = try #require(take(&schedule, at: 0.2, panel: true))
        schedule.finish(unread, panelPresent: false)
        #expect(take(&schedule, at: 0.4, panel: true) == nil)
        #expect(take(&schedule, at: 0.5, panel: true) == nil)
        #expect(take(&schedule, at: 0.6, panel: true)?.mode == .gear)
    }

    // MARK: - The 2026-10-27 reports' timing, with derived entries

    struct Shown {
        let stage: GearDropStage
        let from: Double
        let until: Double
        let entries: [GearDropEntry]
    }

    /// Frames at the constrained analysis interval; each read finishes by the
    /// next frame. `override` replaces what a read at about that time saw.
    func replay(_ panels: [Shown], start: Double, end: Double, paced: Bool,
                override: (time: Double, evidence: GearDropFrameEvidence)? = nil)
        -> (reads: [Double], groups: [GearDropSummary]) {
        var schedule = GameTextSchedule(), tracker = GearDropTracker()
        var pending: (GameTextSchedule.Request, GearDropFrameEvidence)?
        var reads: [Double] = [], groups: [GearDropSummary] = []
        var overridden = false
        var time = start
        while time <= end + 1e-9 {
            let shown = panels.first { $0.from <= time + 1e-9 && time < $0.until - 1e-9 }
            if let (request, evidence) = pending {
                schedule.finish(request, panelPresent: evidence.stage == .portal || evidence.stage == .bonus)
                if let closed = tracker.accept(evidence) { groups.append(closed) }
                pending = nil
            }
            if let closed = tracker.observe(at: time, panelCandidate: shown != nil) { groups.append(closed) }
            // As the app: the panel pace only until the tracker's panel is settled.
            if let request = take(&schedule, at: time, panel: shown != nil,
                                  paced: paced && !tracker.currentPanelSettled), let shown {
                reads.append(time)
                var evidence = GearDropFrameEvidence(sourceTime: time, stage: shown.stage, entries: shown.entries)
                if let override, !overridden, abs(override.time - time) < Self.frameInterval / 2 + 0.05 {
                    evidence = GearDropFrameEvidence(sourceTime: time, stage: override.evidence.stage,
                                                     entries: override.evidence.entries,
                                                     unreadableRows: override.evidence.unreadableRows)
                    overridden = true
                }
                pending = (request, evidence)
            }
            time += Self.frameInterval
        }
        if let closed = tracker.finish(at: end, reason: "test") { groups.append(closed) }
        return (reads, groups)
    }

    static func entry(_ column: Int, _ row: Int, _ item: String, level: Int? = nil, _ quantity: Int,
                      red: Bool) -> GearDropEntry {
        GearDropEntry(column: column, row: row, item: item, levelState: level == nil ? .notApplicable : .known,
                      level: level, quantity: quantity, multiplied: red)
    }

    func portalPanel(_ groups: [GearDropSummary]) -> GearDropSummary.Panel? {
        groups.first?.panels.first { $0.stage == .portal }
    }

    func same(_ stored: [GearDropEntry], _ shown: [GearDropEntry]) -> Bool {
        stored.map { [$0.item ?? "?", "\($0.level ?? 0)", "\($0.quantity)", "\($0.position)"] }
            == shown.map { [$0.item ?? "?", "\($0.level ?? 0)", "\($0.quantity)", "\($0.position)"] }
    }

    @Test("Hack 10 of 2026-10-27: a portal panel up about 0.3 s after its first read keeps its three items")
    func reportHack10() {
        // First read 599.860; Bonus first read mid-slide at 600.260, so it
        // came in about 0.1 s before: the portal panel shows until ~600.16.
        let portal = [Self.entry(0, 0, "Portal Key", 1, red: false),
                      Self.entry(1, 0, "Resonator", level: 8, 1, red: false),
                      Self.entry(0, 1, "Resonator", level: 7, 1, red: false)]
        let bonus = [Self.entry(0, 0, "Portal Key", 1, red: false),
                     Self.entry(1, 0, "Power Cube", level: 7, 1, red: false),
                     Self.entry(0, 1, "XMP Burster", level: 7, 1, red: false),
                     Self.entry(1, 1, "XMP Burster", level: 6, 1, red: false),
                     Self.entry(0, 2, "Resonator", level: 8, 1, red: false),
                     Self.entry(1, 2, "Resonator", level: 7, 3, red: false)]
        let panels = [Shown(stage: .portal, from: 0, until: 0.3, entries: portal),
                      Shown(stage: .bonus, from: 0.3, until: 2.5, entries: bonus)]
        let before = replay(panels, start: 0, end: 3, paced: false)
        #expect(portalPanel(before.groups)?.entries.isEmpty == true, "the reported loss")
        let after = replay(panels, start: 0, end: 3, paced: true)
        #expect(after.groups.count == 1)
        let stored = portalPanel(after.groups)
        #expect(stored.map { same($0.entries, portal) } == true, "\(String(describing: stored))")
        #expect(stored?.entries.allSatisfy { $0.multiplied == false } == true)
        let bonusPanel = after.groups.first?.panels.first { $0.stage == .bonus }
        #expect(bonusPanel.map { same($0.entries, bonus) } == true)
    }

    @Test("Hack 6 of 2026-10-27: an unreadable second read no longer leaves the portal panel empty")
    func reportHack6() {
        // First read 351.090, an unreadable one at 351.490 (2 rows, none
        // parsed), Bonus mid-slide at 351.890: the portal shows until ~351.69.
        let portal = [Self.entry(0, 0, "Portal Key", 2, red: true),
                      Self.entry(1, 0, "Resonator", level: 7, 3, red: true)]
        let bonus = [Self.entry(0, 0, "Multi-Hack", 2, red: true),
                     Self.entry(1, 0, "Power Cube", level: 7, 1, red: true),
                     Self.entry(0, 1, "XMP Burster", level: 8, 1, red: true),
                     Self.entry(1, 1, "XMP Burster", level: 7, 3, red: true),
                     Self.entry(0, 2, "XMP Burster", level: 6, 1, red: true),
                     Self.entry(1, 2, "Resonator", level: 7, 5, red: true)]
        let panels = [Shown(stage: .portal, from: 0, until: 0.6, entries: portal),
                      Shown(stage: .bonus, from: 0.6, until: 3, entries: bonus)]
        let unread = (time: 0.4, evidence: GearDropFrameEvidence(sourceTime: 0.4, stage: .portal, unreadableRows: 2))
        let before = replay(panels, start: 0, end: 3.5, paced: false, override: unread)
        #expect(portalPanel(before.groups)?.entries.isEmpty == true, "the reported loss")
        let after = replay(panels, start: 0, end: 3.5, paced: true, override: unread)
        #expect(after.groups.count == 1)
        let stored = portalPanel(after.groups)
        #expect(stored.map { same($0.entries, portal) } == true, "\(String(describing: stored))")
        #expect(stored?.entries.allSatisfy { $0.multiplied == true } == true)
    }

    @Test("A confirmed panel left on screen goes back to the slow pace; the next panel speeds up again")
    func settledPanelSlowsDown() {
        let portal = [Self.entry(0, 0, "Resonator", level: 7, 1, red: false)]
        let bonus = [Self.entry(0, 0, "XMP Burster", level: 8, 2, red: false)]
        let panels = [Shown(stage: .portal, from: 0, until: 2, entries: portal),
                      Shown(stage: .bonus, from: 2, until: 4, entries: bonus)]
        let reads = replay(panels, start: 0, end: 4.5, paced: true).reads
        let tenths = reads.map { Int(($0 * 10).rounded()) }
        // Two reads 0.2 s apart confirm the portal panel, then every 0.4 s; the
        // Bonus panel, unconfirmed, gets its second read 0.2 s after its first.
        #expect(Array(tenths.prefix(3)) == [0, 2, 6], "\(tenths)")
        let firstBonus = reads.firstIndex { $0 >= 2 - 1e-9 }
        #expect(firstBonus.map { Int(((reads[$0 + 1] - reads[$0]) * 10).rounded()) } == 2, "\(tenths)")
        #expect(reads.count <= 13, "about half the 21 reads of the normal pace: \(reads.count)")
    }

    @Test("A portal panel that leaves before a second read still stores nothing: one read never counts")
    func singleReadStillDropped() {
        let portal = [Self.entry(0, 0, "Resonator", level: 7, 1, red: true)]
        let panels = [Shown(stage: .portal, from: 0, until: 0.15, entries: portal),
                      Shown(stage: .bonus, from: 0.15, until: 1.5, entries: portal)]
        let after = replay(panels, start: 0, end: 2, paced: true)
        #expect(after.groups.count == 1)
        #expect(portalPanel(after.groups)?.entries.isEmpty == true)
        #expect(portalPanel(after.groups)?.partial == true)
    }
}
