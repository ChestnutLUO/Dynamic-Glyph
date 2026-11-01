import Foundation
import Testing
@testable import GlyphRecognition

/// Build 103, decision (a): a new gear panel is told by its geometry
/// (`GameTextSchedule.observeGearPanel`). It stops the gear read in flight,
/// which keeps the lane until it returns; the new panel's first read then has
/// no spacing. Sparks and flicker can't keep stopping one panel's reads, and
/// header reads keep their limits. Geometry is the 2026-10-28 session's
/// (times and bounds only): panels slide in from 0.03 below their settled top.
@Suite("Build 103: the new-panel signal on the shared lane")
struct GearNewPanelScheduleTests {
    static let panelPace = GameTextSchedule.Pace(minimumInterval: 0.1, gearInterval: 0.2)

    static func bounds(_ top: Double, height: Double = 0.1309) -> GearDropPanelBounds {
        GearDropPanelBounds(top: top, bottom: top + height)
    }
    static let settled = bounds(0.2847)
    static let slide = [0.3155, 0.3097, 0.3026, 0.2883].map { bounds($0) }

    /// One analysed frame: the new-panel check, then a constrained take.
    func frame(_ schedule: inout GameTextSchedule, at time: Double, _ bounds: GearDropPanelBounds?,
               unconfirmed: Bool = false, settled: Bool = false, readsHeader: Bool = false)
        -> (stop: GameTextSchedule.Request?, request: GameTextSchedule.Request?) {
        let stop = schedule.observeGearPanel(bounds, at: time, previousPanelUnconfirmed: unconfirmed)
        let request = schedule.take(at: time, panelCandidate: false, resultEligible: false, minimumInterval: 0.2,
                                    gearCandidate: bounds != nil, readsHeader: readsHeader, headerInterval: 1,
                                    gearInterval: 0.4, gearPanelPace: settled ? nil : Self.panelPace)
        return (stop, request)
    }

    @Test("A new panel stops the read in flight; it keeps the lane until it returns, then the new panel is read at once")
    func stopsAndReadsAtOnce() throws {
        var schedule = GameTextSchedule()
        // A settled portal panel read at 1.0 s (its panel already confirmed).
        _ = schedule.observeGearPanel(Self.settled, at: 0.9)
        let old = try #require(frame(&schedule, at: 1.0, Self.settled, settled: true).request)
        #expect(old.mode == .gear)
        #expect(frame(&schedule, at: 1.05, Self.settled, settled: true).stop == nil)
        // Its Bonus panel slides in at 1.1 s.
        let first = frame(&schedule, at: 1.1, Self.slide[0], settled: true)
        #expect(first.stop == old)
        #expect(first.request == nil, "the stopped read still owns the lane")
        #expect(schedule.cancelledGearRequest == old && schedule.newGearPanel)
        #expect(frame(&schedule, at: 1.15, Self.slide[1], settled: true).request == nil)
        schedule.finish(old)
        #expect(schedule.inFlight == nil && schedule.cancelledGearRequest == nil)
        // 0.25 s after the old read: a constrained gear read waits 0.4 s, any
        // read 0.2 s. The new panel's first doesn't.
        let next = try #require(frame(&schedule, at: 1.25, Self.slide[3], settled: true).request)
        #expect(next.mode == .gear && next.sourceTime == 1.25)
        #expect(!schedule.newGearPanel)
    }

    @Test("A stopped read lends the new panel no pace, and is no miss unless the reads before it were misses")
    func stoppedIsNoMiss() throws {
        // A panel its reads found: the stopped read is no miss, so two plain
        // misses after it still leave the 0.4-s cadence.
        var schedule = GameTextSchedule()
        _ = schedule.observeGearPanel(Self.settled, at: -0.05)
        schedule.finish(try #require(frame(&schedule, at: 0, Self.settled).request), panelPresent: true)
        let second = try #require(frame(&schedule, at: 0.2, Self.settled).request)
        #expect(frame(&schedule, at: 0.3, Self.slide[0]).stop == second)
        schedule.finish(second, panelPresent: true)
        #expect(!schedule.readsGearPanel, "its finding is the old panel's")
        schedule.finish(try #require(frame(&schedule, at: 0.35, Self.slide[1]).request))
        schedule.finish(try #require(frame(&schedule, at: 0.75, Self.settled).request))
        #expect(frame(&schedule, at: 1.15, Self.settled).request?.mode == .gear, "two misses: not backed off")

        // A candidate whose reads found nothing: the stopped read counts, so
        // it backs off after three reads, as before.
        var failing = GameTextSchedule()
        failing.finish(try #require(frame(&failing, at: 0, Self.settled).request))
        _ = failing.observeGearPanel(Self.settled, at: 0.35)
        let stopped = try #require(frame(&failing, at: 0.4, Self.settled).request)
        #expect(frame(&failing, at: 0.5, Self.slide[0]).stop == stopped)
        failing.finish(stopped)
        failing.finish(try #require(frame(&failing, at: 0.55, Self.slide[1]).request))
        #expect(frame(&failing, at: 0.95, Self.settled).request == nil, "backed off to a second")
        #expect(frame(&failing, at: 1.55, Self.settled).request?.mode == .gear)
    }

    @Test("A read started while its panel slid in is not stopped by that panel settling, nor are later reads by jitter")
    func ownSlideIsNotNew() {
        var schedule = GameTextSchedule()
        var stops = 0, reads = 0
        // The panel slides in at 0, then stays 2 s with ±2-px spark jitter
        // and the settled ±0.0007; every read takes 0.3 s.
        var pending: (GameTextSchedule.Request, Double)?
        for step in 0..<40 {
            let time = Double(step) * 0.05
            let jitter = [0, 0.0015, -0.0007, 0.0012, -0.0015][step % 5]
            let shown = step < 4 ? Self.slide[step] : Self.bounds(0.2847 + jitter, height: 0.1309 - jitter / 2)
            if let current = pending, time + 1e-9 >= current.1 { schedule.finish(current.0, panelPresent: true); pending = nil }
            let result = frame(&schedule, at: time, shown)
            if result.stop != nil { stops += 1 }
            if let request = result.request { reads += 1; pending = (request, time + 0.3) }
        }
        #expect(stops == 0)
        #expect(reads >= 5)
        #expect(!schedule.newGearPanel)
    }

    @Test("Flicker can stop a panel's reads at most every other read: the read after a stopped one always returns")
    func flickerCannotStarve() {
        for period in [2, 3, 4, 6, 8] {
            var schedule = GameTextSchedule()
            var pending: (GameTextSchedule.Request, Double, Bool)?
            var finished = 0, stopped = 0, consecutive = 0, worst = 0
            // A settled panel whose detected top jumps 0.02 for one frame
            // every `period` frames (a spark), for 6 s; reads take 0.35 s.
            for step in 0..<120 {
                let time = Double(step) * 0.05
                let shown = step % period == period - 1 ? Self.bounds(0.3047) : Self.settled
                if let current = pending, time + 1e-9 >= current.1 {
                    schedule.finish(current.0, panelPresent: true)
                    if schedule.cancelledGearRequest == nil, pending?.2 == true {
                        stopped += 1; consecutive += 1; worst = max(worst, consecutive)
                    } else { finished += 1; consecutive = 0 }
                    pending = nil
                }
                let result = frame(&schedule, at: time, shown)
                if let stop = result.stop, stop == pending?.0 { pending?.2 = true; pending?.1 = time + 0.02 }
                if let request = result.request { pending = (request, time + 0.35, false) }
            }
            #expect(worst <= 1, "period \(period): \(stopped) stopped in a row at most \(worst)")
            #expect(stopped <= finished + 1 && finished >= 6, "period \(period): \(finished) returned, \(stopped) stopped")
        }
    }

    @Test("Bounds alternating every frame by 0.02 stop at most every other read: the read after a stopped one returns")
    func alternatingIsBounded() {
        var schedule = GameTextSchedule()
        var pending: (GameTextSchedule.Request, Double, Bool)?
        var finished = 0, stopped = 0, consecutive = 0, worst = 0
        for step in 0..<80 {
            let time = Double(step) * 0.05
            if let current = pending, time + 1e-9 >= current.1 {
                schedule.finish(current.0, panelPresent: true)
                if current.2 { stopped += 1; consecutive += 1; worst = max(worst, consecutive) }
                else { finished += 1; consecutive = 0 }
                pending = nil
            }
            let result = frame(&schedule, at: time, step % 2 == 0 ? Self.settled : Self.bounds(0.3047))
            if let stop = result.stop, stop == pending?.0 { pending?.2 = true; pending?.1 = time + 0.02 }
            if let request = result.request { pending = (request, time + 0.35, false) }
        }
        #expect(worst <= 1, "\(stopped) stopped, at most \(worst) in a row")
        #expect(finished >= stopped && finished >= 5, "\(finished) returned, \(stopped) stopped")
    }

    @Test("A panel that drops out for a frame and comes back in place is not new; one that comes back elsewhere is")
    func dropOut() throws {
        for (back, new) in [(Self.settled, false), (Self.bounds(0.2847, height: 0.1667), true), (Self.slide[0], true)] {
            var schedule = GameTextSchedule()
            _ = schedule.observeGearPanel(Self.settled, at: -0.05)
            let read = try #require(frame(&schedule, at: 0, Self.settled).request)
            _ = frame(&schedule, at: 0.05, nil)
            let result = frame(&schedule, at: 0.1, back)
            #expect((result.stop == read) == new, "\(back)")
            #expect(schedule.newGearPanel == new)
        }
    }

    @Test("A read of an unconfirmed panel runs on; the new panel's first read still has no spacing")
    func unconfirmedRunsOn() throws {
        var schedule = GameTextSchedule()
        _ = schedule.observeGearPanel(Self.settled, at: 0.9)
        let old = try #require(frame(&schedule, at: 1.0, Self.settled).request)
        let result = frame(&schedule, at: 1.1, Self.slide[0], unconfirmed: true)
        #expect(result.stop == nil && schedule.cancelledGearRequest == nil && schedule.newGearPanel)
        schedule.finish(old, panelPresent: true)
        #expect(frame(&schedule, at: 1.15, Self.slide[1], unconfirmed: true).request?.mode == .gear)
    }

    @Test("A candidate backed off by misses gets no new-panel events, as before")
    func backedOff() throws {
        var schedule = GameTextSchedule()
        var time = 0.0
        while true {
            _ = frame(&schedule, at: time, Self.settled)
            if let request = schedule.inFlight { schedule.finish(request) }
            time += 0.1
            if time > 1.25 { break }
        }
        // Three misses: 0, 0.4, 0.8; the next read is a second later.
        let read = try #require(frame(&schedule, at: 1.8, Self.settled).request)
        let result = frame(&schedule, at: 1.9, Self.slide[0])
        #expect(result.stop == nil && !schedule.newGearPanel)
        schedule.finish(read)
        #expect(frame(&schedule, at: 2.0, Self.slide[1]).request == nil, "still a second apart")
    }

    @Test("Callers that never call the check get build 102's schedule; with it, only a new panel's first read moves")
    func withoutTheCheck() {
        func reads(observing: Bool) -> [Int] {
            var schedule = GameTextSchedule(), out: [Int] = []
            for step in 0..<30 {
                let time = Double(step) / 10
                let shown = step < 12 ? Self.settled : step == 12 ? nil : step < 17 ? Self.slide[min(3, step - 13)] : Self.settled
                if observing { _ = schedule.observeGearPanel(shown, at: time) }
                if let request = schedule.take(at: time, panelCandidate: false, resultEligible: false,
                                               minimumInterval: 0.2, gearCandidate: shown != nil, readsHeader: false,
                                               gearInterval: 0.4, gearPanelPace: Self.panelPace) {
                    out.append(step); schedule.finish(request, panelPresent: true)
                }
            }
            return out
        }
        let old = reads(observing: false)
        #expect(old == [0, 2, 4, 6, 8, 10, 14, 16, 18, 20, 22, 24, 26, 28], "\(old)")
        // Observed, the panel sliding in at 1.3 s after a frame without one
        // is new: it is read at once, not 0.4 s after the last read.
        let new = reads(observing: true)
        #expect(new == [0, 2, 4, 6, 8, 10, 13, 15, 17, 19, 21, 23, 25, 27, 29], "\(new)")
    }

    @Test("Header reads are not starved: a flickering candidate leaves them as many as before")
    func headersNotStarved() {
        func headers(observing: Bool, panelPresent: Bool, untitled: Bool) -> (headers: Int, gear: Int) {
            var schedule = GameTextSchedule()
            var pending: (GameTextSchedule.Request, Double)?
            var headers = 0, gear = 0
            for step in 0..<200 {
                let time = Double(step) * 0.05
                // A candidate that flickers: two frames here, two 0.02 lower.
                let shown = (step / 2) % 2 == 0 ? Self.settled : Self.bounds(0.3047)
                if let current = pending, time + 1e-9 >= current.1 {
                    schedule.finish(current.0, panelPresent: panelPresent && current.0.mode == .gear,
                                    untitledPanel: untitled && current.0.mode == .gear)
                    pending = nil
                }
                if observing, let stop = schedule.observeGearPanel(shown, at: time), let current = pending,
                   stop == current.0 {
                    pending = (current.0, min(current.1, time + 0.02))
                }
                guard let request = schedule.take(at: time, panelCandidate: false, resultEligible: false,
                                                  minimumInterval: 0.2, gearCandidate: true, readsHeader: true,
                                                  headerInterval: 1, gearInterval: 0.4,
                                                  gearPanelPace: Self.panelPace) else { continue }
                if request.mode == .gear { gear += 1 } else { headers += 1 }
                pending = (request, time + (request.mode == .gear ? 0.35 : 0.1))
            }
            return (headers, gear)
        }
        for (present, untitled) in [(false, false), (false, true), (true, false)] {
            let before = headers(observing: false, panelPresent: present, untitled: untitled)
            let after = headers(observing: true, panelPresent: present, untitled: untitled)
            #expect(after.headers >= before.headers, "found \(present), untitled \(untitled): \(before) → \(after)")
        }
        // A candidate that finds no panel backs off and lets the header in, as before.
        #expect(headers(observing: true, panelPresent: false, untitled: false).headers >= 5)
    }
}
