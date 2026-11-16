import Foundation
import Testing
@testable import GlyphRecognition

/// A gear read that started while its panel was
/// still sliding in is stopped when a new panel slides in before the old one
/// rests: its top more than `newPanelShift` further down the screen than
/// where the read started. A panel slides in from below and settles upwards,
/// so its own settling never does that, nor does spark jitter (±2 px). The
/// same rules hold: one stop per read, none for the read after a stopped one,
/// none while the old panel's rows are unconfirmed. Lane timelines as
/// `GearNewPanelLaneTests` (injected reads, no Vision): every short-portal
/// case of a synthetic sweep where the new-panel lane, without this rule,
/// lost a Bonus panel that the old lane kept.
@Suite("New-panel lane: a new panel while the old one still slides in")
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

    /// A field recording at 495.3 s, as the lane log recorded it (gearSettle on, Mac
    /// real time): the portal panel rests at top 0.2863; its Bonus panel
    /// slides in from 495.29 s, and the slide's first step (0.3183 to 0.3160)
    /// eases in within the still tolerance before 0.0061, 0.0099 and 0.0137.
    static let easedSlide: [(time: Double, top: Double, bottom: Double)] = [
        (494.991667, 0.2862595, 0.4190840), (495.041667, 0.2862595, 0.4190840),
        (495.091667, 0.2862595, 0.4190840), (495.141667, 0.2862595, 0.4190840),
        (495.191667, 0.2862595, 0.4190840), (495.241667, 0.2862595, 0.4190840),
        (495.291667, 0.3183206, 0.4511450), (495.341667, 0.3160305, 0.4488550),
        (495.391667, 0.3099237, 0.4427481), (495.441667, 0.3000000, 0.4328244),
        (495.491667, 0.2862595, 0.4190840), (495.541667, 0.2862595, 0.4190840),
        (495.591667, 0.2862595, 0.4190840), (495.641667, 0.2862595, 0.4190840)]

    @Test("A new panel's first read is not stopped when its slide's first step eases in (a field recording, 495.3 s)",
          arguments: [0, 1])
    func easedFirstStep(_ startFrame: Int) throws {
        var schedule = GameTextSchedule()
        var first: GameTextSchedule.Request?
        let slideStart = 6
        for (index, sample) in Self.easedSlide.enumerated() {
            let shown = GearDropPanelBounds(top: sample.top, bottom: sample.bottom)
            if first == nil, index >= slideStart, index < slideStart + startFrame {
                // The lane is busy elsewhere: the first read starts a frame later,
                // on the eased step itself.
                #expect(schedule.observeGearPanel(shown, at: sample.time) == nil)
                continue
            }
            let result = frame(&schedule, at: sample.time, shown)
            #expect(result.stop == nil, "frame \(sample.time)")
            guard let request = result.request else { continue }
            if index < slideStart {
                // Reads of the resting portal panel, which return at once (the
                // gearSettle reissue that left the lane idle).
                schedule.finish(request, panelPresent: true)
            } else if first == nil {
                first = request
            }
        }
        let read = try #require(first)
        #expect(read.sourceTime == Self.easedSlide[slideStart + startFrame].time)
        #expect(schedule.inFlight == read && schedule.cancelledGearRequest == nil)
    }

    @Test("A new panel replacing that first read during the eased slide still stops it")
    func easedSlideThenNewPanel() throws {
        var schedule = GameTextSchedule()
        var first: GameTextSchedule.Request?
        for sample in Self.easedSlide.prefix(9) {
            let result = frame(&schedule, at: sample.time, GearDropPanelBounds(top: sample.top, bottom: sample.bottom))
            if let request = result.request {
                if sample.time < 495.29 { schedule.finish(request, panelPresent: true) } else { first = first ?? request }
            }
        }
        let read = try #require(first)
        // Another panel slides in from below, its top 0.012 under where the read started.
        let stop = frame(&schedule, at: 495.441667, GearDropPanelBounds(top: 0.3303, bottom: 0.4631)).stop
        #expect(stop == read && schedule.newGearPanel)
    }

    /// The sweep's cases: constrained, a 0.25-s portal panel, then the Bonus.
    static let cases: [(bonus: Double, cost: Double)] = [(0.45, 0.25), (0.45, 0.35), (0.7, 0.55), (1.0, 0.55)]

    @Test("Short portal panel, constrained: the Bonus panel the old lane kept is kept, at every start nothing the old lane keeps is lost",
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
