import Foundation
import Testing
@testable import GlyphRecognition

/// Build 103, fix 1 (Ato 1954): a gear read that started while its panel was
/// still sliding in is stopped when a new panel slides in before the old one
/// rests: its top more than `newPanelShift` further down the screen than
/// where the read started. A panel slides in from below and settles upwards,
/// so its own settling never does that, nor does spark jitter (±2 px). The
/// same rules hold: one stop per read, none for the read after a stopped one,
/// none while the old panel's rows are unconfirmed. Lane timelines as
/// `GearNewPanelLaneTests` (injected reads, no Vision): every short-portal
/// case of the 2026-10-30 synthetic sweep where build 103 lost a Bonus panel
/// that build 102 kept, before this fix.
@Suite("Build 103: a new panel while the old one still slides in")
struct GearNewPanelSlideTests {
    typealias Sim = GearLaneSimulation
    static let pace = GameTextSchedule.Pace(minimumInterval: 0.1, gearInterval: 0.2)
    static func bounds(_ top: Double, height: Double = 0.1309) -> GearDropPanelBounds {
        GearDropPanelBounds(top: top, bottom: top + height)
    }
    static let slide = Sim.slide.map { bounds($0) }

    func frame(_ schedule: inout GameTextSchedule, at time: Double, _ shown: GearDropPanelBounds?,
               unconfirmed: Bool = false) -> (stop: GameTextSchedule.Request?, request: GameTextSchedule.Request?) {
        let stop = schedule.observeGearPanel(shown, at: time, previousPanelUnconfirmed: unconfirmed)
        let request = schedule.take(at: time, panelCandidate: false, resultEligible: false, minimumInterval: 0.2,
                                    gearCandidate: shown != nil, readsHeader: false, gearInterval: 0.4,
                                    gearPanelPace: Self.pace)
        return (stop, request)
    }

    @Test("A read started on any slide frame is never stopped by its panel settling upwards, with spark jitter",
          arguments: 0..<4)
    func settlingNeverStops(_ first: Int) throws {
        var schedule = GameTextSchedule()
        if first > 0 { _ = schedule.observeGearPanel(Self.slide[first - 1], at: -0.05) }
        let read = try #require(frame(&schedule, at: 0, Self.slide[first]).request)
        let jitter = [0, 0.0015, -0.0015, 0.0012, -0.0007, 0.0015, -0.0012, 0]
        let rest = Self.slide[(first + 1)...] + jitter.map { Self.bounds(0.2847 + $0, height: 0.1309 - $0 / 2) }
        for (index, shown) in rest.enumerated() {
            #expect(frame(&schedule, at: 0.05 * Double(index + 1), shown).stop == nil, "frame \(index)")
        }
        #expect(schedule.inFlight == read && !schedule.newGearPanel)
    }

    @Test("A new panel sliding in before the old one rests stops a read started on the old one's late slide frames")
    func newPanelBeforeRest() throws {
        for first in 0..<4 {
            var schedule = GameTextSchedule()
            if first > 0 { _ = schedule.observeGearPanel(Self.slide[first - 1], at: -0.05) }
            let read = try #require(frame(&schedule, at: 0, Self.slide[first]).request)
            let result = frame(&schedule, at: 0.05, Self.bounds(0.3155, height: 0.1667))
            // From the first two slide frames (0.3155, 0.3097) the new panel's
            // first frame is within 0.01: the next one, still sliding, isn't.
            #expect((result.stop == read) == (first >= 2), "slide frame \(first)")
            if first >= 2 {
                schedule.finish(read)
                #expect(frame(&schedule, at: 0.1, Self.bounds(0.3097, height: 0.1667)).request?.mode == .gear,
                        "the new panel's first read has no spacing")
            }
        }
    }

    @Test("Before rest, the same rules: an unconfirmed panel's read runs on; the read after a stopped one is never stopped")
    func sameRules() throws {
        var schedule = GameTextSchedule()
        _ = schedule.observeGearPanel(Self.slide[2], at: -0.05)
        let read = try #require(frame(&schedule, at: 0, Self.slide[3]).request)
        #expect(frame(&schedule, at: 0.05, Self.bounds(0.3155), unconfirmed: true).stop == nil)
        schedule.finish(read, panelPresent: true)
        // A read stopped, then the next read of the new panel, started while
        // it slides in: a further jump down doesn't stop it.
        var other = GameTextSchedule()
        _ = other.observeGearPanel(Self.slide[2], at: -0.05)
        let first = try #require(frame(&other, at: 0, Self.slide[3]).request)
        #expect(frame(&other, at: 0.05, Self.slide[0]).stop == first)
        other.finish(first)
        let second = try #require(frame(&other, at: 0.1, Self.slide[1]).request)
        #expect(frame(&other, at: 0.15, Self.bounds(0.3255)).stop == nil)
        #expect(other.inFlight == second)
    }

    /// The sweep's cases: constrained, a 0.25-s portal panel, then the Bonus.
    static let cases: [(bonus: Double, cost: Double)] = [(0.45, 0.25), (0.45, 0.35), (0.7, 0.55), (1.0, 0.55)]

    @Test("Short portal panel, constrained: the Bonus panel 102 kept is kept, at every start nothing 102 keeps is lost",
          arguments: 0..<4)
    func shortPortalCases(_ index: Int) {
        let (bonus, cost) = Self.cases[index]
        let frames = Sim.nothing(from: 0, seconds: 0.3) + Sim.panel(.portal, from: 0.3, seconds: 0.25, height: 0.1309)
            + Sim.panel(.bonus, from: 0.55, seconds: bonus, height: 0.1667) + Sim.nothing(from: 0.55 + bonus, seconds: 0.5)
        // The start the sweep found: the second 10-Hz phase, a header read in flight from 0.3 s.
        let found = Sim.run(frames, lane103: true, cancelLatency: 0.05, phase: 1, headerAt: 0.3) { _ in cost }
        #expect(Sim.kept(found, .bonus), "Bonus \(bonus) s at \(cost): reads \(found.reads), stopped \(found.cancels)")
        #expect(Sim.wrongItems(found) == 0 && found.groups.count == 1 && found.mostInFlight == 1)
        for phase in [0, 1] {
            for headerAt in [nil, 0.3, 0.25, 0.2, 0.15] as [Double?] {
                let old = Sim.run(frames, lane103: false, phase: phase, headerAt: headerAt) { _ in cost }
                let new = Sim.run(frames, lane103: true, cancelLatency: 0.05, phase: phase, headerAt: headerAt) { _ in cost }
                for stage in [GearDropStage.portal, .bonus] where Sim.kept(old, stage) {
                    #expect(Sim.kept(new, stage), "phase \(phase), header \(String(describing: headerAt)), \(stage)")
                }
                #expect(Sim.wrongItems(new) == 0 && new.groups.count == max(1, old.groups.count))
            }
        }
    }
}
