import CoreGraphics
import Foundation
import Testing
import GlyphRecognitionCxx
@testable import GlyphRecognition
@testable import GlyphRecognitionImages

// The pace area's C++ arm (glyph_logic_pace.h through GlyphRecognitionCxx)
// held to the Swift oracle: every scenario of the oracle tests run through
// both arms with the same inputs and compared output for output, plus seeded
// random walks compared after every step.

// MARK: - Shared

/// Doubles equal, or both NaN.
private func sameDouble(_ a: Double?, _ b: Double?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return a == b || (a.isNaN && b.isNaN)
    default: return false
    }
}

/// A seeded source time: mostly forward, sometimes back, repeated or not
/// finite, as captures and replays produce them.
private func paceTime(_ random: inout PaceRandom, clock: inout Double) -> Double {
    switch random.below(100) {
    case 0..<78: clock += random.double(0...0.3)
    case 78..<86: clock -= random.double(0...5)
    case 86..<91: break
    case 91..<95: clock += random.double(1...10)
    case 95..<97: return .nan
    case 97: return .infinity
    case 98: return -.infinity
    default: clock += 0.05
    }
    return clock
}

// MARK: - Pace

/// Both arms of the gate's pace, driven together and compared after every call.
private final class PacePair {
    var swift: AnalysisRateController
    let cxx: CxxAnalysisRateController
    private(set) var steps = 0

    init(policy: AnalysisRateController.Policy = AnalysisRateController.Policy()) {
        swift = AnalysisRateController(policy: policy)
        cxx = CxxAnalysisRateController(policy: policy)
        #expect(cxx.policy == swift.policy)
    }

    @discardableResult
    func decide(at time: Double, gate: LumaGateReading?, busy: Bool = false, inHack: Bool = false,
                constrained: Bool = false) -> AnalysisRateController.Decision {
        let expected = swift.decide(at: time, gate: gate, busy: busy, inHack: inHack, constrained: constrained)
        let actual = cxx.decide(at: time, gate: gate, busy: busy, inHack: inHack, constrained: constrained)
        compare(expected, actual, "decide at \(time)")
        return expected
    }

    @discardableResult
    func advanceStill(at time: Double, busy: Bool = false, inHack: Bool = false,
                      constrained: Bool = false) -> AnalysisRateController.Decision {
        let expected = swift.advanceStill(at: time, busy: busy, inHack: inHack, constrained: constrained)
        let actual = cxx.advanceStill(at: time, busy: busy, inHack: inHack, constrained: constrained)
        compare(expected, actual, "still at \(time)")
        return expected
    }

    func reset() {
        swift.reset(); cxx.reset()
        compare(nil, nil, "reset")
    }

    private func compare(_ expected: AnalysisRateController.Decision?, _ actual: AnalysisRateController.Decision?,
                         _ context: String) {
        steps += 1
        #expect(expected == actual, "\(context)")
        #expect(swift.mode == cxx.mode && swift.enteredCandidate == cxx.enteredCandidate
                && swift.switchedScreen == cxx.switchedScreen, "\(context)")
    }

    func run(from start: Double, seconds: Double, gate: (Int) -> LumaGateReading?, busy: Bool = false,
             inHack: Bool = false, constrained: Bool = false) {
        for index in 0..<Int(seconds * 20) {
            decide(at: start + Double(index) * 0.05, gate: gate(index), busy: busy, inHack: inHack,
                   constrained: constrained)
        }
    }

    func still(from start: Double, seconds: Double, busy: Bool = false, inHack: Bool = false) {
        for index in 1...Int(seconds * 4) {
            advanceStill(at: start + Double(index) * 0.25, busy: busy, inHack: inHack, constrained: false)
        }
    }
}

@Suite("C++ pace: analysis rate")
struct CxxPaceControllerTests {
    static let map = LumaGateReading(darkFraction: 0.05, brightFraction: 0.4, cells: [40, 60], isCandidate: false)
    static let mapScrolled = LumaGateReading(darkFraction: 0.06, brightFraction: 0.45, cells: [80, 20], isCandidate: false)
    static let hack = LumaGateReading(darkFraction: 0.95, brightFraction: 0.02, cells: [3, 9], isCandidate: true)
    static let glyph = LumaGateReading(darkFraction: 0.93, brightFraction: 0.04, cells: [3, 15], isCandidate: true)
    static let night = LumaGateReading(darkFraction: 0.7, brightFraction: 0.05, cells: [10, 22], isCandidate: true)
    static let moved = LumaGateReading(darkFraction: 0.68, brightFraction: 0.06, cells: [22, 10], isCandidate: true)

    @Test("Every oracle scenario of AnalysisRateControllerTests gives the same decisions and state")
    func oracleScenarios() {
        var steps = 0
        // backOffAndReturn
        do {
            let pair = PacePair()
            pair.run(from: 10, seconds: 3, gate: { $0 % 2 == 0 ? Self.map : Self.mapScrolled })
            pair.decide(at: 13.01, gate: Self.hack)
            pair.decide(at: 13.06, gate: Self.glyph)
            pair.decide(at: 14.06, gate: Self.glyph)
            pair.run(from: 14, seconds: 3, gate: { _ in Self.map }, constrained: true)
            pair.decide(at: 17, gate: Self.hack, constrained: true)
            steps += pair.steps
        }
        // stillScreen
        do {
            let pair = PacePair()
            pair.run(from: 0, seconds: 5, gate: { _ in Self.hack })
            pair.decide(at: 5, gate: Self.glyph)
            pair.decide(at: 5.05, gate: Self.glyph, busy: true)
            pair.run(from: 6, seconds: 5, gate: { _ in Self.hack })
            pair.decide(at: 11.5, gate: Self.map)
            steps += pair.steps
        }
        // busy
        do {
            let pair = PacePair()
            pair.run(from: 0, seconds: 6, gate: { _ in Self.map }, inHack: true)
            pair.run(from: 6, seconds: 6, gate: { _ in Self.map }, busy: true)
            steps += pair.steps
        }
        // withoutPixels
        do {
            let pair = PacePair()
            pair.run(from: 0, seconds: 6, gate: { _ in nil })
            pair.run(from: 6, seconds: 3, gate: { _ in Self.map })
            pair.run(from: 9, seconds: 1, gate: { _ in nil })
            steps += pair.steps
        }
        // constrained
        do {
            let pair = PacePair()
            pair.decide(at: 0, gate: Self.hack, constrained: true)
            pair.decide(at: 0.1, gate: Self.glyph, inHack: true, constrained: true)
            pair.run(from: 1, seconds: 3, gate: { _ in Self.map }, constrained: true)
            pair.decide(at: 4, gate: Self.map, constrained: true)
            steps += pair.steps
        }
        // restartedClock
        do {
            let pair = PacePair()
            pair.run(from: 100, seconds: 3, gate: { _ in Self.map })
            pair.decide(at: 5, gate: Self.map)
            steps += pair.steps
        }
        // stillLooksSettle
        for reading in [Self.hack, Self.map] {
            let still = PacePair(), frames = PacePair()
            still.decide(at: 0, gate: reading)
            frames.decide(at: 0, gate: reading)
            still.still(from: 0, seconds: 6)
            for index in 1...24 { frames.decide(at: Double(index) * 0.25, gate: reading) }
            steps += still.steps + frames.steps
        }
        for (reading, seconds) in [(Self.hack, 5.0), (Self.map, 3.0)] {
            let pair = PacePair()
            pair.decide(at: 10, gate: reading)
            pair.still(from: 10, seconds: seconds)
            steps += pair.steps
        }
        // stillWhileBusy
        do {
            let pair = PacePair()
            pair.decide(at: 0, gate: Self.map, inHack: true)
            pair.still(from: 0, seconds: 6, inHack: true)
            pair.still(from: 6, seconds: 6, busy: true)
            pair.still(from: 12, seconds: 3)
            steps += pair.steps
        }
        // stillWithoutPixels
        do {
            let pair = PacePair()
            pair.run(from: 0, seconds: 1, gate: { _ in nil })
            pair.still(from: 1, seconds: 6)
            pair.decide(at: 8, gate: Self.map)
            pair.run(from: 8.05, seconds: 4, gate: { _ in nil })
            steps += pair.steps
        }
        // frameAfterStillLooks
        do {
            let pair = PacePair()
            pair.decide(at: 100, gate: Self.hack)
            pair.still(from: 100, seconds: 5)
            pair.decide(at: 104.98, gate: Self.hack)
            pair.decide(at: 104.99, gate: Self.glyph)
            pair.decide(at: 104.995, gate: Self.glyph, busy: true)
            pair.run(from: 105, seconds: 2.5, gate: { _ in Self.hack })
            pair.still(from: 105, seconds: 5)
            pair.advanceStill(at: 50)
            pair.decide(at: 5, gate: Self.hack)
            steps += pair.steps
        }
        for constrained in [false, true] {
            // darkChangingMap
            let map = PacePair()
            map.run(from: 50, seconds: 60, gate: { $0 % 2 == 0 ? Self.night : Self.moved }, constrained: constrained)
            #expect(CxxAnalysisRateController.headerInterval(mode: map.cxx.mode, inHack: false, constrained: constrained)
                == AnalysisRateController.headerInterval(mode: map.swift.mode, inHack: false, constrained: constrained))
            // evidenceWakes
            let wakes = PacePair()
            wakes.run(from: 0, seconds: 3, gate: { _ in Self.night }, constrained: constrained)
            wakes.decide(at: 3, gate: Self.night, busy: true, constrained: constrained)
            wakes.decide(at: 3.05, gate: Self.night, inHack: true, constrained: constrained)
            wakes.run(from: 3.1, seconds: 3, gate: { _ in Self.night }, constrained: constrained)
            wakes.advanceStill(at: 6.2, busy: true, constrained: constrained)
            // screenSwitch
            let switching = PacePair()
            switching.run(from: 0, seconds: 3, gate: { $0 % 2 == 0 ? Self.night : Self.moved }, constrained: constrained)
            switching.decide(at: 3, gate: Self.hack, constrained: constrained)
            switching.run(from: 3.05, seconds: 1.5, gate: { $0 % 2 == 0 ? Self.hack : Self.glyph },
                          constrained: constrained)
            let fading = PacePair()
            fading.run(from: 0, seconds: 3, gate: { _ in Self.night }, constrained: constrained)
            for (index, cells) in [[8, 20], [7, 17], [5, 13], [3, 9]].enumerated() {
                let gate = LumaGateReading(darkFraction: 0.8, brightFraction: 0.04, cells: cells.map(UInt8.init),
                                           isCandidate: true)
                fading.decide(at: 3 + Double(index) * 0.05, gate: gate, constrained: constrained)
            }
            steps += map.steps + wakes.steps + switching.steps + fading.steps
        }
        // headerIntervals
        for mode in [AnalysisRateController.Mode.active, .resting, .quiet] {
            for inHack in [false, true] {
                for constrained in [false, true] {
                    #expect(CxxAnalysisRateController.headerInterval(mode: mode, inHack: inHack, constrained: constrained)
                        == AnalysisRateController.headerInterval(mode: mode, inHack: inHack, constrained: constrained))
                }
            }
        }
        #expect(steps > 2_000, "\(steps) steps compared")
    }

    static func randomGate(_ random: inout PaceRandom, base: inout Int) -> LumaGateReading? {
        if random.chance(12) { return nil }
        if random.chance(10) { base = random.below(256) }
        let count = 2 + random.below(5)
        let cells = (0..<count).map { _ in UInt8(clamping: base + random.below(21) - 10) }
        return LumaGateReading(darkFraction: random.double(0...1), brightFraction: random.double(0...1), cells: cells,
                               isCandidate: random.chance(60))
    }

    static func randomPolicy(_ random: inout PaceRandom) -> AnalysisRateController.Policy {
        var policy = AnalysisRateController.Policy()
        policy.activeInterval = random.double(0.01...0.2)
        policy.quietInterval = random.double(0.1...0.6)
        policy.constrainedActiveInterval = random.double(0.02...0.3)
        policy.constrainedQuietInterval = random.double(0.2...1)
        policy.settle = random.double(0.2...3)
        policy.changeThreshold = random.below(10)
        policy.switchMeanJump = random.double(1...30)
        policy.switchWindow = random.double(0.05...1)
        policy.switchBurst = random.double(0.1...2)
        return policy
    }

    @Test("A seeded random walk of 5,000 looks gives the same decisions and state after every step",
          arguments: [1, 2, 3] as [UInt64])
    func randomWalk(seed: UInt64) {
        var random = PaceRandom(seed: seed)
        let pair = PacePair(policy: seed == 1 ? AnalysisRateController.Policy() : Self.randomPolicy(&random))
        var clock = 0.0, base = 20
        for _ in 0..<5_000 {
            let time = paceTime(&random, clock: &clock)
            let busy = random.chance(15), inHack = random.chance(15), constrained = random.chance(30)
            switch random.below(100) {
            case 0..<75: pair.decide(at: time, gate: Self.randomGate(&random, base: &base), busy: busy, inHack: inHack,
                                     constrained: constrained)
            case 75..<97: pair.advanceStill(at: time, busy: busy, inHack: inHack, constrained: constrained)
            default: pair.reset()
            }
        }
        #expect(pair.steps == 5_000)
    }
}

// MARK: - Text lane

/// Both arms of the text lane, compared after every call, including how
/// often each asks `admitsHeader`.
private final class SchedulePair {
    var swift = GameTextSchedule()
    let cxx = CxxGameTextSchedule()
    private(set) var steps = 0
    private(set) var requests = 0

    @discardableResult
    func take(at time: Double, panelCandidate: Bool, resultEligible: Bool, minimumInterval: Double = 0.1,
              gearCandidate: Bool = false, headerPriority: Bool = false, portalCandidate: Bool = false,
              commandCandidate: Bool = false, readsHeader: Bool = true, headerInterval: Double? = nil,
              gearInterval: Double = 0.2, gearPanelPace: GameTextSchedule.Pace? = nil,
              admits: Bool = true) -> GameTextSchedule.Request? {
        var swiftAsked = 0, cxxAsked = 0
        let expected = swift.take(at: time, panelCandidate: panelCandidate, resultEligible: resultEligible,
                                  minimumInterval: minimumInterval, gearCandidate: gearCandidate,
                                  headerPriority: headerPriority, portalCandidate: portalCandidate,
                                  commandCandidate: commandCandidate, readsHeader: readsHeader,
                                  headerInterval: headerInterval, gearInterval: gearInterval,
                                  gearPanelPace: gearPanelPace,
                                  admitsHeader: { swiftAsked += 1; return admits })
        let actual = cxx.take(at: time, panelCandidate: panelCandidate, resultEligible: resultEligible,
                              minimumInterval: minimumInterval, gearCandidate: gearCandidate,
                              headerPriority: headerPriority, portalCandidate: portalCandidate,
                              commandCandidate: commandCandidate, readsHeader: readsHeader,
                              headerInterval: headerInterval, gearInterval: gearInterval,
                              gearPanelPace: gearPanelPace,
                              admitsHeader: { cxxAsked += 1; return admits })
        steps += 1
        if expected != nil { requests += 1 }
        #expect(expected == actual, "take at \(time)")
        #expect(swiftAsked == cxxAsked, "admission asked at \(time)")
        compareState("take at \(time)")
        return expected
    }

    func finish(_ request: GameTextSchedule.Request, panelPresent: Bool = false, untitledPanel: Bool = false) {
        swift.finish(request, panelPresent: panelPresent, untitledPanel: untitledPanel)
        cxx.finish(request, panelPresent: panelPresent, untitledPanel: untitledPanel)
        steps += 1
        compareState("finish \(request)")
    }

    /// `observeGearPanel`: the request each arm asks to stop.
    @discardableResult
    func observe(_ bounds: GearDropPanelBounds?, at time: Double,
                 unconfirmed: Bool = false) -> GameTextSchedule.Request? {
        let expected = swift.observeGearPanel(bounds, at: time, previousPanelUnconfirmed: unconfirmed)
        let actual = cxx.observeGearPanel(bounds, at: time, previousPanelUnconfirmed: unconfirmed)
        steps += 1
        if expected != nil { stops += 1 }
        #expect(expected == actual, "observe \(String(describing: bounds)) at \(time)")
        compareState("observe at \(time)")
        return expected
    }

    /// One analysed frame as `GearNewPanelScheduleTests.frame` drives it: the
    /// new-panel check, then a constrained take.
    @discardableResult
    func frame(at time: Double, _ bounds: GearDropPanelBounds?, unconfirmed: Bool = false, settled: Bool = false,
               readsHeader: Bool = false) -> (stop: GameTextSchedule.Request?, request: GameTextSchedule.Request?) {
        let stop = observe(bounds, at: time, unconfirmed: unconfirmed)
        let request = take(at: time, panelCandidate: false, resultEligible: false, minimumInterval: 0.2,
                           gearCandidate: bounds != nil, readsHeader: readsHeader, headerInterval: 1, gearInterval: 0.4,
                           gearPanelPace: settled ? nil : NewPanelLane.pace)
        return (stop, request)
    }

    private(set) var stops = 0

    private func compareState(_ context: String) {
        #expect(swift.inFlight == cxx.inFlight, "\(context): in flight")
        #expect(swift.readsGearPanel == cxx.readsGearPanel && swift.newGearPanel == cxx.newGearPanel
                && swift.cancelledGearRequest == cxx.cancelledGearRequest, "\(context): panel state")
    }
}

@Suite("C++ pace: text lane")
struct CxxPaceScheduleTests {
    @Test("Every oracle scenario of the header cadence and portal lane gives the same requests")
    func oracleScenarios() throws {
        // unchangedHeaderAdmission
        do {
            let pair = SchedulePair()
            let first = try #require(pair.take(at: 0, panelCandidate: false, resultEligible: false, headerInterval: 0.5))
            pair.finish(first)
            pair.take(at: 0.5, panelCandidate: false, resultEligible: false, headerInterval: 0.5, admits: false)
            pair.take(at: 0.55, panelCandidate: false, resultEligible: false, headerInterval: 0.5)
        }
        // sharedLaneBypassesHeaderAdmission
        for mode in [GameTextSchedule.Mode.result, .gear, .portal, .command] {
            let pair = SchedulePair()
            pair.take(at: 0, panelCandidate: mode == .result, resultEligible: true, gearCandidate: mode == .gear,
                      portalCandidate: mode == .portal, commandCandidate: mode == .command, readsHeader: false,
                      admits: false)
        }
        // skippedHeaderKeepsCandidateBookkeeping
        do {
            let pair = SchedulePair()
            let rejected = try #require(pair.take(at: 0, panelCandidate: true, resultEligible: true))
            pair.finish(rejected, panelPresent: false)
            pair.take(at: 0.5, panelCandidate: false, resultEligible: true, admits: false)
            pair.take(at: 0.55, panelCandidate: true, resultEligible: true)
        }
        // headerOnly
        do {
            let pair = SchedulePair()
            for index in 0..<40 {
                if let request = pair.take(at: Double(index) * 0.05, panelCandidate: false, resultEligible: false,
                                           headerInterval: 0.5) { pair.finish(request) }
            }
            for index in 0..<10 {
                if let request = pair.take(at: 10 + Double(index) * 0.05, panelCandidate: false, resultEligible: false,
                                           portalCandidate: true, headerInterval: 0.5) { pair.finish(request) }
            }
            let fast = SchedulePair()
            for index in 0..<20 {
                if let request = fast.take(at: Double(index) * 0.05, panelCandidate: false, resultEligible: false) {
                    fast.finish(request)
                }
            }
        }
        // PortalLevelTests.schedule
        do {
            let pair = SchedulePair()
            let input = try #require(pair.take(at: 0, panelCandidate: false, resultEligible: false, headerPriority: true,
                                               portalCandidate: true))
            pair.finish(input)
            let portal = try #require(pair.take(at: 0.2, panelCandidate: false, resultEligible: false,
                                                portalCandidate: true))
            pair.finish(portal)
            let header = try #require(pair.take(at: 0.32, panelCandidate: false, resultEligible: false,
                                                portalCandidate: true))
            pair.finish(header)
            pair.take(at: 0.5, panelCandidate: false, resultEligible: false, gearCandidate: true, portalCandidate: true)
        }
    }

    @Test("A seeded random walk of 5,000 takes and finishes gives the same requests after every step",
          arguments: [1, 2, 3] as [UInt64])
    func randomWalk(seed: UInt64) {
        var random = PaceRandom(seed: seed)
        let pair = SchedulePair()
        var clock = 0.0
        for _ in 0..<5_000 {
            switch random.below(100) {
            case 0..<75:
                let time = paceTime(&random, clock: &clock)
                pair.take(at: time, panelCandidate: random.chance(30), resultEligible: random.chance(40),
                          minimumInterval: random.chance(70) ? 0.1 : random.pick([0.2, 0.05, random.double(0...0.5)]),
                          gearCandidate: random.chance(25), headerPriority: random.chance(15),
                          portalCandidate: random.chance(15), commandCandidate: random.chance(10),
                          readsHeader: random.chance(85),
                          headerInterval: random.chance(50) ? nil : random.pick([0.5, 1.0, 0.1, random.double(0...2)]),
                          gearInterval: random.pick([0.2, 0.4, random.double(0...1.5)]),
                          gearPanelPace: random.chance(50) ? nil : NewPanelLane.pace, admits: random.chance(80))
            case 75..<95 where pair.swift.inFlight != nil:
                pair.finish(pair.swift.inFlight!, panelPresent: random.chance(50), untitledPanel: random.chance(20))
            default:
                // A request that is not in flight: stale, repeated or made up.
                let modes: [GameTextSchedule.Mode] = [.header, .result, .gear, .portal, .command]
                pair.finish(.make(id: random.below(5_000), mode: random.pick(modes), sourceTime: clock),
                            panelPresent: random.chance(50))
            }
        }
        #expect(pair.steps == 5_000)
        #expect(pair.requests > 500, "\(pair.requests) requests")
    }
}

// MARK: - New-panel lane

/// The geometry of `GearNewPanelScheduleTests` and `GearNewPanelSlideTests`:
/// a field session's panels, sliding in from 0.03 below their top.
enum NewPanelLane {
    static let pace = GameTextSchedule.Pace(minimumInterval: 0.1, gearInterval: 0.2)
    static func bounds(_ top: Double, height: Double = 0.1309) -> GearDropPanelBounds {
        GearDropPanelBounds(top: top, bottom: top + height)
    }
    static let settled = bounds(0.2847)
    static let slide = [0.3155, 0.3097, 0.3026, 0.2883].map { bounds($0) }
}

@Suite("C++ pace: the new-panel lane")
struct CxxPaceNewPanelTests {
    typealias Lane = NewPanelLane

    @Test("Every oracle scenario of the new-panel check, panel pace and untitled reads gives the same requests and state")
    func oracleScenarios() throws {
        // GearNewPanelScheduleTests.stopsAndReadsAtOnce
        do {
            let pair = SchedulePair()
            pair.observe(Lane.settled, at: 0.9)
            let old = try #require(pair.frame(at: 1.0, Lane.settled, settled: true).request)
            pair.frame(at: 1.05, Lane.settled, settled: true)
            #expect(pair.frame(at: 1.1, Lane.slide[0], settled: true).stop == old)
            pair.frame(at: 1.15, Lane.slide[1], settled: true)
            pair.finish(old)
            pair.frame(at: 1.25, Lane.slide[3], settled: true)
        }
        // GearNewPanelScheduleTests.stoppedIsNoMiss, both halves
        do {
            let pair = SchedulePair()
            pair.observe(Lane.settled, at: -0.05)
            pair.finish(try #require(pair.frame(at: 0, Lane.settled).request), panelPresent: true)
            let second = try #require(pair.frame(at: 0.2, Lane.settled).request)
            pair.frame(at: 0.3, Lane.slide[0])
            pair.finish(second, panelPresent: true)
            pair.finish(try #require(pair.frame(at: 0.35, Lane.slide[1]).request))
            pair.finish(try #require(pair.frame(at: 0.75, Lane.settled).request))
            pair.frame(at: 1.15, Lane.settled)
            let failing = SchedulePair()
            failing.finish(try #require(failing.frame(at: 0, Lane.settled).request))
            failing.observe(Lane.settled, at: 0.35)
            let stopped = try #require(failing.frame(at: 0.4, Lane.settled).request)
            failing.frame(at: 0.5, Lane.slide[0])
            failing.finish(stopped)
            failing.finish(try #require(failing.frame(at: 0.55, Lane.slide[1]).request))
            failing.frame(at: 0.95, Lane.settled)
            failing.frame(at: 1.55, Lane.settled)
        }
        // GearNewPanelScheduleTests.ownSlideIsNotNew
        do {
            let pair = SchedulePair()
            var pending: (GameTextSchedule.Request, Double)?
            for step in 0..<40 {
                let time = Double(step) * 0.05
                let jitter = [0, 0.0015, -0.0007, 0.0012, -0.0015][step % 5]
                let shown = step < 4 ? Lane.slide[step] : Lane.bounds(0.2847 + jitter, height: 0.1309 - jitter / 2)
                if let current = pending, time + 1e-9 >= current.1 { pair.finish(current.0, panelPresent: true); pending = nil }
                if let request = pair.frame(at: time, shown).request { pending = (request, time + 0.3) }
            }
        }
        // flickerCannotStarve and alternatingIsBounded
        for period in [2, 3, 4, 6, 8] {
            let pair = SchedulePair()
            var pending: (GameTextSchedule.Request, Double)?
            for step in 0..<120 {
                let time = Double(step) * 0.05
                let shown = period == 2 ? (step % 2 == 0 ? Lane.settled : Lane.bounds(0.3047))
                    : step % period == period - 1 ? Lane.bounds(0.3047) : Lane.settled
                if let current = pending, time + 1e-9 >= current.1 { pair.finish(current.0, panelPresent: true); pending = nil }
                let result = pair.frame(at: time, shown)
                if let stop = result.stop, stop == pending?.0 { pending?.1 = time + 0.02 }
                if let request = result.request { pending = (request, time + 0.35) }
            }
            #expect(pair.stops > 0, "period \(period)")
        }
        // dropOut
        for back in [Lane.settled, Lane.bounds(0.2847, height: 0.1667), Lane.slide[0]] {
            let pair = SchedulePair()
            pair.observe(Lane.settled, at: -0.05)
            _ = try #require(pair.frame(at: 0, Lane.settled).request)
            pair.frame(at: 0.05, nil)
            pair.frame(at: 0.1, back)
        }
        // unconfirmedRunsOn
        do {
            let pair = SchedulePair()
            pair.observe(Lane.settled, at: 0.9)
            let old = try #require(pair.frame(at: 1.0, Lane.settled).request)
            pair.frame(at: 1.1, Lane.slide[0], unconfirmed: true)
            pair.finish(old, panelPresent: true)
            pair.frame(at: 1.15, Lane.slide[1], unconfirmed: true)
        }
        // backedOff
        do {
            let pair = SchedulePair()
            var time = 0.0
            while time <= 1.25 {
                pair.frame(at: time, Lane.settled)
                if let request = pair.swift.inFlight { pair.finish(request) }
                time += 0.1
            }
            let read = try #require(pair.frame(at: 1.8, Lane.settled).request)
            pair.frame(at: 1.9, Lane.slide[0])
            pair.finish(read)
            pair.frame(at: 2.0, Lane.slide[1])
        }
        // withoutTheCheck, both ways
        for observing in [false, true] {
            let pair = SchedulePair()
            for step in 0..<30 {
                let time = Double(step) / 10
                let shown = step < 12 ? Lane.settled : step == 12 ? nil : step < 17 ? Lane.slide[min(3, step - 13)]
                    : Lane.settled
                if observing { pair.observe(shown, at: time) }
                if let request = pair.take(at: time, panelCandidate: false, resultEligible: false, minimumInterval: 0.2,
                                           gearCandidate: shown != nil, readsHeader: false, gearInterval: 0.4,
                                           gearPanelPace: Lane.pace) {
                    pair.finish(request, panelPresent: true)
                }
            }
        }
        // headersNotStarved, every variant
        for observing in [false, true] {
            for (present, untitled) in [(false, false), (false, true), (true, false)] {
                let pair = SchedulePair()
                var pending: (GameTextSchedule.Request, Double)?
                for step in 0..<200 {
                    let time = Double(step) * 0.05
                    let shown = (step / 2) % 2 == 0 ? Lane.settled : Lane.bounds(0.3047)
                    if let current = pending, time + 1e-9 >= current.1 {
                        pair.finish(current.0, panelPresent: present && current.0.mode == .gear,
                                    untitledPanel: untitled && current.0.mode == .gear)
                        pending = nil
                    }
                    if observing, let stop = pair.observe(shown, at: time), let current = pending, stop == current.0 {
                        pending = (current.0, min(current.1, time + 0.02))
                    }
                    guard let request = pair.take(at: time, panelCandidate: false, resultEligible: false,
                                                  minimumInterval: 0.2, gearCandidate: true, readsHeader: true,
                                                  headerInterval: 1, gearInterval: 0.4, gearPanelPace: Lane.pace)
                    else { continue }
                    pending = (request, time + (request.mode == .gear ? 0.35 : 0.1))
                }
            }
        }
        // GearNewPanelSlideTests: settling never stops; a new panel before rest
        for first in 0..<4 {
            let pair = SchedulePair()
            if first > 0 { pair.observe(Lane.slide[first - 1], at: -0.05) }
            let read = try #require(pair.frame(at: 0, Lane.slide[first]).request)
            let jitter = [0, 0.0015, -0.0015, 0.0012, -0.0007, 0.0015, -0.0012, 0]
            let rest = Lane.slide[(first + 1)...] + jitter.map { Lane.bounds(0.2847 + $0, height: 0.1309 - $0 / 2) }
            for (index, shown) in rest.enumerated() { pair.frame(at: 0.05 * Double(index + 1), shown) }
            pair.finish(read)
            let other = SchedulePair()
            if first > 0 { other.observe(Lane.slide[first - 1], at: -0.05) }
            let started = try #require(other.frame(at: 0, Lane.slide[first]).request)
            other.frame(at: 0.05, Lane.bounds(0.3155, height: 0.1667))
            other.finish(started)
            other.frame(at: 0.1, Lane.bounds(0.3097, height: 0.1667))
        }
        // GearNewPanelSlideTests.easedFirstStep and easedSlideThenNewPanel:
        // A field recording's eased slide at 495.3 s, the first read on its first or
        // second frame, then the rest or another panel from below.
        for (startFrame, replaced) in [(0, false), (1, false), (0, true)] {
            let pair = SchedulePair()
            for (index, sample) in GearNewPanelSlideTests.easedSlide.enumerated() {
                var shown = GearDropPanelBounds(top: sample.top, bottom: sample.bottom)
                if replaced, index == 9 { shown = GearDropPanelBounds(top: 0.3303, bottom: 0.4631) }
                if index >= 6, index < 6 + startFrame {
                    pair.observe(shown, at: sample.time)
                    continue
                }
                if let request = pair.frame(at: sample.time, shown).request, index < 6 {
                    pair.finish(request, panelPresent: true)
                }
            }
        }
        // GearPanelPaceTests: a found panel keeps the pace until it leaves
        do {
            let pair = SchedulePair()
            var time = 0.0
            while time < 2.0 {
                let panel = time < 1.5
                if let request = pair.take(at: time, panelCandidate: false, resultEligible: false, minimumInterval: 0.2,
                                           gearCandidate: panel, readsHeader: false, gearInterval: 0.4,
                                           gearPanelPace: Lane.pace) {
                    pair.finish(request, panelPresent: time < 1.2)
                }
                time += 0.05
            }
        }
        // GearUntitledPanelTests: untitled reads never back off; they give no pace
        for untitled in [false, true] {
            let pair = SchedulePair()
            for step in 0..<40 {
                if let request = pair.take(at: Double(step) * 0.1, panelCandidate: false, resultEligible: false,
                                           minimumInterval: 0.2, gearCandidate: true, readsHeader: false,
                                           gearInterval: 0.4, gearPanelPace: Lane.pace) {
                    pair.finish(request, panelPresent: false, untitledPanel: untitled)
                }
            }
        }
    }

    @Test("Seeded random walks of 5,000 panel frames, slides, sparks and drop-outs give the same requests after every step",
          arguments: [1, 2, 3, 4] as [UInt64])
    func randomWalk(seed: UInt64) {
        var random = PaceRandom(seed: seed)
        let pair = SchedulePair()
        var time = 0.0
        var top = 0.2847, height = 0.1309
        var slideFrames = 0
        var pending: (GameTextSchedule.Request, Double)?
        var cancelledFinishes = 0, freeGrants = 0
        for _ in 0..<5_000 {
            time += random.chance(95) ? 0.05 : random.double(0...0.6)
            // The panel: rests with spark jitter, slides in anew from 0.03 below,
            // drops out, jumps (a new panel in place or elsewhere), or is gone.
            var shown: GearDropPanelBounds?
            switch random.below(100) {
            case 0..<6:
                top = random.pick([0.2847, 0.30, 0.27, random.double(0.2...0.4)]) + 0.03; slideFrames = 4
                height = random.pick([0.1309, 0.1667, random.double(0.08...0.2)])
                shown = Lane.bounds(top, height: height)
            case 6..<12: shown = nil
            case 12..<15:
                shown = Lane.bounds(top + random.pick([0.011, -0.011, 0.02, 0.0099, 0.0101]), height: height)
            default:
                if slideFrames > 0 { top -= random.double(0.003...0.015); slideFrames -= 1 }
                let jitter = random.pick([0, 0.0015, -0.0007, 0.0012, -0.0015, 0.003, -0.0031])
                shown = Lane.bounds(top + jitter, height: height - jitter / 2)
            }
            if random.chance(1) { shown = Lane.bounds(.nan, height: height) }
            if let current = pending, time + 1e-9 >= current.1 {
                if pair.swift.cancelledGearRequest == current.0 { cancelledFinishes += 1 }
                pair.finish(current.0, panelPresent: current.0.mode == .gear && random.chance(60),
                            untitledPanel: random.chance(15))
                pending = nil
            }
            let unconfirmed = random.chance(25)
            if random.chance(90), let stop = pair.observe(shown, at: time, unconfirmed: unconfirmed),
               let current = pending, stop == current.0 {
                pending = (current.0, min(current.1, time + random.pick([0, 0.02, 0.05, 0.4])))
            }
            let constrained = random.chance(60)
            let wasNew = pair.swift.newGearPanel
            guard let request = pair.take(
                at: time, panelCandidate: random.chance(10), resultEligible: random.chance(10),
                minimumInterval: constrained ? 0.2 : 0.1, gearCandidate: shown != nil,
                headerPriority: random.chance(5), portalCandidate: random.chance(5), commandCandidate: random.chance(3),
                readsHeader: random.chance(70), headerInterval: random.pick([nil, 1, 0.5]),
                gearInterval: constrained ? 0.4 : 0.2, gearPanelPace: constrained && random.chance(70) ? Lane.pace : nil)
            else { continue }
            if wasNew && request.mode == .gear { freeGrants += 1 }
            pending = (request, time + random.pick([0.03, 0.1, 0.2, 0.35, 0.9]))
        }
        // The walk must reach the rules it compares.
        #expect(pair.stops > 20 && cancelledFinishes > 20 && freeGrants > 20,
                "\(pair.stops) stops, \(cancelledFinishes) stopped reads finished, \(freeGrants) new panels read")
    }
}

// MARK: - Language memory

/// Both arms of the language memory, with the changes each reported.
private final class LanguagePair {
    final class Changes: @unchecked Sendable {
        let lock = NSLock()
        var values: [GameLanguage] = []
        func append(_ language: GameLanguage) { lock.withLock { values.append(language) } }
        var all: [GameLanguage] { lock.withLock { values } }
    }

    let swiftChanges = Changes(), cxxChanges = Changes()
    let swift: GameLanguageMemory
    let cxx: CxxGameLanguageMemory
    private(set) var steps = 0

    init(language: GameLanguage, isAutomatic: Bool, retryInterval: Double = 1) {
        let swiftChanges = swiftChanges, cxxChanges = cxxChanges
        swift = GameLanguageMemory(language: language, isAutomatic: isAutomatic, retryInterval: retryInterval) {
            swiftChanges.append($0)
        }
        cxx = CxxGameLanguageMemory(language: language, isAutomatic: isAutomatic, retryInterval: retryInterval) {
            cxxChanges.append($0)
        }
        compare("init")
    }

    func compare(_ context: String) {
        steps += 1
        #expect(swift.state == cxx.state && swift.current == cxx.current && swift.isConfirmed == cxx.isConfirmed
                && swift.isAutomatic == cxx.isAutomatic, "\(context)")
        #expect(swiftChanges.all == cxxChanges.all, "\(context)")
    }

    func alternatives(at time: Double, on screen: GameLanguageMemory.Screen) {
        #expect(swift.alternatives(at: time, on: screen) == cxx.alternatives(at: time, on: screen), "\(time) \(screen)")
        compare("alternatives")
    }

    func found(_ language: GameLanguage) {
        swift.found(language); cxx.found(language)
        compare("found \(language)")
    }

    func remember(_ language: GameLanguage, at time: Double, bounds: GearDropPanelBounds) {
        swift.rememberPanelReading(language, at: time, bounds: bounds)
        cxx.rememberPanelReading(language, at: time, bounds: bounds)
        compare("remember")
    }

    func panel(at time: Double, bounds: GearDropPanelBounds) {
        #expect(swift.panelReadingLanguage(at: time, bounds: bounds) == cxx.panelReadingLanguage(at: time, bounds: bounds),
                "panel at \(time)")
        compare("panel")
    }
}

@Suite("C++ pace: game language memory")
struct CxxPaceLanguageMemoryTests {
    @Test("Every oracle scenario of the language memory gives the same languages, states and changes")
    func oracleScenarios() {
        // languageMemory
        let memory = LanguagePair(language: .english, isAutomatic: true, retryInterval: 3)
        memory.alternatives(at: 10, on: .result)
        memory.alternatives(at: 11, on: .result)
        memory.alternatives(at: 11, on: .notice)
        memory.alternatives(at: 13, on: .result)
        memory.found(.english)
        memory.found(.japanese)
        memory.found(.japanese)
        memory.alternatives(at: 20, on: .panel)
        let chosen = LanguagePair(language: .korean, isAutomatic: false)
        chosen.alternatives(at: 10, on: .notice)
        chosen.found(.english)
        // temporaryPanelReader
        let bounds = GearDropPanelBounds(top: 0.3, bottom: 0.5)
        let panel = LanguagePair(language: .english, isAutomatic: true)
        panel.remember(.japanese, at: 10, bounds: bounds)
        panel.panel(at: 10.1, bounds: bounds)
        panel.panel(at: 16, bounds: bounds)
        panel.remember(.japanese, at: 20, bounds: bounds)
        panel.panel(at: 19, bounds: bounds)
        panel.remember(.japanese, at: 20, bounds: bounds)
        panel.panel(at: 20.1, bounds: GearDropPanelBounds(top: 0.3, bottom: 0.6))
        panel.remember(.japanese, at: 20, bounds: bounds)
        panel.found(.simplifiedChinese)
        panel.panel(at: 20.1, bounds: bounds)
        let chosenPanel = LanguagePair(language: .english, isAutomatic: false)
        chosenPanel.remember(.japanese, at: 1, bounds: bounds)
        chosenPanel.panel(at: 1.1, bounds: bounds)
        // startingGuess
        let guesses: [(GameLanguage?, [String])] = [(.korean, ["ja-JP"]), (nil, ["zh-Hant-TW", "en"]),
                                                     (nil, ["zh-Hans-CN"]), (nil, ["fr-FR", "ja-JP"]), (nil, ["fr-FR"])]
        for (remembered, preferred) in guesses {
            #expect(CxxGameLanguageMemory.startingGuess(remembered: remembered, preferredLanguages: preferred)
                == GameLanguageMemory.startingGuess(remembered: remembered, preferredLanguages: preferred))
        }
    }

    @Test("Seeded random walks of 2,000 calls give the same languages, states and changes",
          arguments: [1, 2, 3] as [UInt64])
    func randomWalk(seed: UInt64) {
        var random = PaceRandom(seed: seed)
        let pair = LanguagePair(language: random.pick(GameLanguage.allCases), isAutomatic: seed != 3,
                                retryInterval: random.double(0...3))
        var clock = 0.0
        let screens: [GameLanguageMemory.Screen] = [.notice, .result, .panel]
        for _ in 0..<2_000 {
            let time = paceTime(&random, clock: &clock)
            let bounds = GearDropPanelBounds(top: 0.3 + Double(random.below(5)) * 0.002,
                                             bottom: 0.5 + Double(random.below(5)) * 0.002)
            switch random.below(4) {
            case 0: pair.alternatives(at: time, on: random.pick(screens))
            case 1: pair.found(random.pick(GameLanguage.allCases))
            case 2: pair.remember(random.pick(GameLanguage.allCases), at: time, bounds: bounds)
            default: pair.panel(at: time, bounds: bounds)
            }
        }
        let codes = ["zh-Hant-TW", "zh-TW", "zh-hk", "ZH-HANT", "zh", "zh-Hans", "ja", "JA-jp", "ko-KR", "en-GB", "fr",
                     "de-DE", "", "z", "zh\u{301}-hant", "e\u{301}n", "jа", "Ｊa"]
        for _ in 0..<1_000 {
            let preferred = (0..<random.below(4)).map { _ in random.pick(codes) }
            let remembered: GameLanguage? = random.chance(20) ? random.pick(GameLanguage.allCases) : nil
            #expect(CxxGameLanguageMemory.startingGuess(remembered: remembered, preferredLanguages: preferred)
                == GameLanguageMemory.startingGuess(remembered: remembered, preferredLanguages: preferred), "\(preferred)")
        }
    }
}

// MARK: - Game text and command parser

@Suite("C++ pace: game text matchers")
struct CxxPaceGameTextTests {
    /// Every matcher on `text`, compared; returns the mismatches.
    static func mismatches(_ swift: GameText, _ cxx: CxxGameText, _ text: String) -> [String] {
        var found: [String] = []
        let expectedNotice = swift.notice(text), actualNotice = cxx.notice(text)
        if expectedNotice?.notice != actualNotice?.notice || expectedNotice?.language != actualNotice?.language {
            found.append("notice")
        }
        if swift.isDroneFooter(text) != cxx.isDroneFooter(text) { found.append("drone") }
        if swift.isHackingLabel(text) != cxx.isHackingLabel(text) { found.append("hacking") }
        if swift.hackingLabelLanguage(text) != cxx.hackingLabelLanguage(text) { found.append("hackingLanguage") }
        if swift.bonusTitleLanguage(text) != cxx.bonusTitleLanguage(text) { found.append("bonusLanguage") }
        if swift.isSpeedLabel(text) != cxx.isSpeedLabel(text) { found.append("speed") }
        if swift.title(text) != cxx.title(text) { found.append("title") }
        if swift.effect(text) != cxx.effect(text) { found.append("effect") }
        if swift.item(named: text) != cxx.item(named: text, clipped: false) { found.append("item") }
        if swift.item(named: text, clipped: true) != cxx.item(named: text, clipped: true) { found.append("clipped") }
        return found.map { "\(swift.language.rawValue) \($0): \(text) [\(CxxTextTests.hex(text))]" }
    }

    @Test("Every string the oracle tests read gives the same matches in every language")
    func oracleStrings() {
        for language in GameLanguage.allCases {
            let swift = GameText(language), cxx = CxxGameText(language)
            var found: [String] = []
            for text in CxxTextTests.oracleStrings { found += Self.mismatches(swift, cxx, text) }
            #expect(found.isEmpty, "\(found.count): \(found.prefix(20))")
        }
    }

    /// The names a language's panels show, as the packs and the oracle tests
    /// give them, to mutate.
    static func names(_ language: GameLanguage) -> [String] {
        var names = GameText.levelledItems.union(GameText.unlevelledItems).sorted()
        for table in GameText(language).tables {
            names += table.items.keys.sorted() + table.leadingWords.keys.sorted() + table.notices.keys.sorted()
            names += [table.bonusTitle, table.bountyTitle, table.droneFooter, table.hackingLabel, table.speedLabel]
            names += table.messageFragments
            names += table.effectSuffixes.map { "ITO EN Transmuter (+) \($0)" }
            names += table.effectPrefixes.map { "\($0) ITO EN (-)" }
        }
        names += ["XMP 能量炮", "动能储存胶囊", "XMPバースター", "Aegis シールド", "ポータル シールド", "ウルトラ ストライク",
                  "能量塔鑰匙", "포탈 쉴드", "이지스 실드", "SoftBank ウルトラリンク", "ジャービス ウイルス", "키네틱 캡슐",
                  "ITO EN (-)", "ITO EN (+)", "ITO EN Transmuter (+)"]
        return names
    }

    static let inserts = ["…", "...", ".", "。", " ", "\t", "\u{3000}", "\u{A0}", "-", "−", "–", "－", "＋", "（", "）", "(",
                          ")", "+", "\u{301}", "\u{3099}", "\u{309A}", "\u{200D}", "·", ":", "：", "A", "^", "1", "8",
                          "\u{FF9F}", "\u{1F600}", "\n", "x"]

    /// One to three random edits of `name`.
    static func mutate(_ name: String, _ random: inout PaceRandom) -> String {
        var characters = Array(name)
        for _ in 0..<(1 + random.below(3)) {
            switch random.below(11) {
            case 0 where !characters.isEmpty: characters = Array(characters.prefix(random.below(characters.count + 1)))
            case 1: characters.append(contentsOf: random.pick(["…", "...", ".", "。", ""]))
            case 2: characters.insert(contentsOf: random.pick(inserts), at: random.below(characters.count + 1))
            case 3 where !characters.isEmpty: characters.remove(at: random.below(characters.count))
            case 4: characters = Array(String(characters).uppercased())
            case 5: characters = Array(String(characters).decomposedStringWithCanonicalMapping)
            case 6: characters = Array(random.pick([" ", "\t", "\u{3000}"]) + String(characters) + random.pick([" ", ""]))
            case 7 where !characters.isEmpty:
                let index = random.below(characters.count)
                characters.insert(characters[index], at: index)
            case 8 where !characters.isEmpty:
                characters[random.below(characters.count)] = random.pick(Array("ーアイポル能量塔키드XMP"))
            case 9: characters = Array(String(characters).precomposedStringWithCanonicalMapping)
            default: characters.insert(contentsOf: " ", at: random.below(characters.count + 1))
            }
        }
        return String(characters)
    }

    @Test("1,000 random mutations of each language's names give the same matches", arguments: GameLanguage.allCases)
    func mutations(language: GameLanguage) {
        var random = PaceRandom(seed: UInt64(GameLanguage.allCases.firstIndex(of: language)! + 100))
        let swift = GameText(language), cxx = CxxGameText(language)
        let names = Self.names(language)
        var found: [String] = []
        var matched = 0
        for _ in 0..<1_000 {
            let text = Self.mutate(random.pick(names), &random)
            found += Self.mismatches(swift, cxx, text)
            if swift.item(named: text) != nil || swift.item(named: text, clipped: true) != nil { matched += 1 }
        }
        #expect(found.isEmpty, "\(found.count): \(found.prefix(20))")
        #expect(matched > 100, "the mutations should still name items often: \(matched)")
    }

    @Test("The command parser reads every oracle line, confidence and language as the Swift parser does")
    func commandParser() {
        let confidences = [0, 0.29, 0.3, 0.49, 0.5, 0.79, 0.8, 0.85, 0.94, 0.95, 1, .nan, -.infinity]
        var random = PaceRandom(seed: 7)
        var compared = 0
        for language in GameLanguage.allCases {
            let swift = CommandNoticeParser(language: language), cxx = CxxCommandNoticeParser(language: language)
            let lines = CxxTextTests.oracleStrings + Self.names(language).map { Self.mutate($0, &random) }
            for line in lines {
                for confidence in confidences {
                    let expected = swift.read([(line, confidence)]), actual = cxx.read([(line, confidence)])
                    #expect(expected == actual || (expected.confidence.isNaN && actual.confidence.isNaN),
                            "\(language) \(line) \(confidence)")
                    compared += 1
                }
            }
            #expect(swift.read([]) == cxx.read([]))
            #expect(swift.read([("NO KEY", 1), ("NO KEY", 1)]) == cxx.read([("NO KEY", 1), ("NO KEY", 1)]))
        }
        // The oracle's own cases.
        for (language, line, confidence) in [(GameLanguage.simplifiedChinese, "复杂入侵", 0.5), (.simplifiedChinese, "复杂入侵", 0.3),
                                             (.english, "COMPLEX HACK", 0.85), (.japanese, "NO KEY", 0.5), (.japanese, "NO KEY", 1)] {
            #expect(CommandNoticeParser(language: language).read([(line, confidence)])
                == CxxCommandNoticeParser(language: language).read([(line, confidence)]))
        }
        for text in ["NO KEY EXTRA", "ONLY", "SPEED", "REQUEST KEV", "DRONE FOOTAGE", "请求钥匙"] {
            #expect(CommandNoticeParser().read([(text, 1)]) == CxxCommandNoticeParser().read([(text, 1)]))
        }
        #expect(compared > 5_000)
    }
}

// MARK: - Command capture

/// What a frame says, comparable across the arms.
private struct PaceFrameFacts: Equatable {
    let id: Int
    let sourceTime: Double
    let isMode: Bool
    let generation: Int
    let signature: [UInt8]?
    let width: Int
    let height: Int

    init(_ frame: CommandNoticeFrame) {
        id = frame.id; sourceTime = frame.sourceTime; isMode = frame.isMode; generation = frame.generation
        signature = frame.signature; width = frame.image.width; height = frame.image.height
    }
}

/// Both arms of the command capture, on the same images, compared after
/// every call.
private final class CapturePair {
    let swift = CommandNoticeCapture()
    let cxx = CxxCommandNoticeCapture()
    private(set) var steps = 0
    /// The latest time a call was given, to ask whether a probe is due
    /// around it.
    private var clock = 0.0

    func compare(_ context: String) {
        steps += 1
        compareProbeDue(context)
        #expect(swift.queue.map(PaceFrameFacts.init) == cxx.queue.map(PaceFrameFacts.init), "\(context)")
        #expect(swift.showsNotice == cxx.showsNotice && swift.modeCandidates == cxx.modeCandidates
                && swift.modeReads == cxx.modeReads && swift.modeReuses == cxx.modeReuses, "\(context)")
        #expect(sameDouble(swift.noticeReadAt, cxx.noticeReadAt), "\(context): notice read at")
    }

    /// `modeProbeDue` on both sides of the one-second gate, and earlier, with
    /// and without a panel. It changes nothing, so asking is not a step.
    func compareProbeDue(_ context: String) {
        for offset in [-1.5, -0.001, 0, 0.5, 0.999, 1, 1.001, 2, 30] {
            for panelShowing in [false, true] {
                let time = clock + offset
                #expect(swift.modeProbeDue(at: time, panelShowing: panelShowing)
                        == cxx.modeProbeDue(at: time, panelShowing: panelShowing),
                        "\(context): probe due at \(time), panel \(panelShowing)")
            }
        }
    }

    func modeProbeDue(at time: Double, panelShowing: Bool = false) -> Bool {
        let expected = swift.modeProbeDue(at: time, panelShowing: panelShowing)
        #expect(expected == cxx.modeProbeDue(at: time, panelShowing: panelShowing), "probe due at \(time)")
        return expected
    }

    func observe(band: CGImage, at time: Double) throws {
        clock = time
        try swift.observe(band: band, at: time)
        try cxx.observe(band: band, at: time)
        compare("observe at \(time)")
    }

    func observeEmptyBand(at time: Double) {
        clock = time
        swift.observeEmptyBand(at: time)
        cxx.observeEmptyBand(at: time)
        compare("observeEmptyBand at \(time)")
    }

    @discardableResult
    func observeMode(in image: CGImage, at time: Double, panelShowing: Bool = false) throws -> Bool {
        clock = time
        let due = modeProbeDue(at: time, panelShowing: panelShowing)
        let expected = try swift.observeMode(in: image, at: time, panelShowing: panelShowing)
        let actual = try cxx.observeMode(in: image, at: time, panelShowing: panelShowing)
        #expect(expected == actual, "observeMode at \(time)")
        // A probe that is not due finds no candidate: skipping its render
        // loses nothing.
        #expect(due || !expected, "observeMode at \(time) found a candidate though no probe was due")
        compare("observeMode at \(time)")
        return expected
    }

    func take(at time: Double) throws -> (swift: CommandNoticeFrame, cxx: CommandNoticeFrame)? {
        clock = time
        let expected = swift.take(at: time), actual = cxx.take(at: time)
        #expect(expected.map(PaceFrameFacts.init) == actual.map(PaceFrameFacts.init), "take at \(time)")
        if let expected, let actual {
            #expect(try ImageDecoder.decode(expected.image).pixels == ImageDecoder.decode(actual.image).pixels)
        }
        compare("take at \(time)")
        guard let expected, let actual else { return nil }
        return (expected, actual)
    }

    func takeDropped() {
        #expect(swift.takeDropped() == cxx.takeDropped())
        compare("takeDropped")
    }

    func accept(_ read: CommandNoticeReading, _ frames: (swift: CommandNoticeFrame, cxx: CommandNoticeFrame)) {
        swift.accept(read, frame: frames.swift)
        cxx.accept(read, frame: frames.cxx)
        compare("accept")
    }

    func interrupt(at time: Double) {
        clock = time
        swift.interrupt(at: time); cxx.interrupt(at: time); compare("interrupt")
    }
    func invalidateQueue(at time: Double) {
        clock = time
        swift.invalidateQueue(at: time); cxx.invalidateQueue(at: time); compare("invalidate")
    }
    func bind(hackID: Int) { swift.bind(hackID: hackID); cxx.bind(hackID: hackID); compare("bind") }
    func cancel() { swift.cancel(); cxx.cancel(); compare("cancel") }

    @discardableResult
    func summary(hackID: Int) -> HackCommandSummary {
        let expected = swift.summary(hackID: hackID)
        #expect(expected == cxx.summary(hackID: hackID), "summary \(hackID)")
        return expected
    }

    /// Takes every frame, reads it with Vision, and accepts the read in both.
    func readAll(at time: Double) throws {
        while let frames = try take(at: time) { accept(try CommandNoticeReader().read(frames.swift), frames) }
    }
}

/// Vision reads, serialized like the oracle's Vision suites.
@Suite("C++ pace: command capture", .serialized, .timeLimit(.minutes(5)))
struct CxxPaceCommandCaptureTests {
    static func band(_ name: String) throws -> CGImage {
        try ReferenceData.requireScreenshots()
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures/Commands"))
        return try #require(ImageDecoder.cgImage(from: Data(contentsOf: url)))
    }

    static func fixture(_ path: String) throws -> CGImage {
        let data = try Data(contentsOf: ReferenceData.fixturesDirectory.appendingPathComponent(path))
        return try #require(ImageDecoder.cgImage(from: data))
    }

    static func overlay() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 602, height: 170, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 70, width: 602, height: 3))
        return try #require(context.makeImage())
    }

    /// A band with grey levels up to 45 and none above: what the band
    /// detector sees as nothing at all.
    static func darkBand() throws -> CGImage {
        let width = 602, height = 170
        let levels = (0..<width * height).map { UInt8(($0 * 7 + $0 / width * 3) % 46) }
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width { data[y * context.bytesPerRow + x] = levels[y * width + x] }
        }
        return try #require(context.makeImage())
    }

    static func letters() throws -> CGImage {
        try DroneFooterProbeTests.strip { context, label in
            context.setFillColor(DroneFooterProbeTests.yellow)
            for index in 0..<12 {
                context.fill(CGRect(x: 205 + Double(index) * 16, y: label.minY + 18, width: 5, height: 20))
            }
        }
    }

    @Test("Every oracle scenario of CommandRecognitionTests' capture gives the same queues, frames and summaries")
    func commandScenarios() throws {
        // epochQueueInvalidationRejectsStaleReadsAndPreservesBoundHack
        do {
            let pair = CapturePair()
            try pair.observe(band: Self.band("no-key"), at: 99)
            let committed = try #require(try pair.take(at: 99))
            pair.accept(.init(notice: .noKey, confidence: 1), committed)
            pair.bind(hackID: 1)
            pair.summary(hackID: 1)
            try pair.observe(band: Self.band("complex"), at: 100)
            let old = try #require(try pair.take(at: 100))
            try pair.observe(band: Self.band("complex"), at: 100.05)
            pair.invalidateQueue(at: 1)
            pair.accept(.init(notice: .complex, confidence: 1), old)
            pair.bind(hackID: 2)
            pair.summary(hackID: 2); pair.summary(hackID: 1)
            try pair.observe(band: Self.band("request-key-single"), at: 1.1)
            let fresh = try #require(try pair.take(at: 1.1))
            pair.accept(.init(notice: .requestKey, confidence: 1), fresh)
            pair.bind(hackID: 3)
            pair.summary(hackID: 3); pair.summary(hackID: 1)
        }
        // futureQueuedCropCannotBeConsumedByRewoundClock
        do {
            let pair = CapturePair()
            try pair.observe(band: Self.band("no-key"), at: 100)
            _ = try pair.take(at: 1)
            pair.takeDropped()
        }
        // recordedNotices
        for name in ["simple", "complex", "no-key", "keys-only", "request-key-single"] {
            let pair = CapturePair()
            try pair.observe(band: Self.band(name), at: 1)
            try pair.readAll(at: 1)
            pair.bind(hackID: 1)
            pair.summary(hackID: 1)
        }
        // everyDeliveredFrameAndDirectReplacement
        do {
            let pair = CapturePair()
            for (time, name) in [(1.0, "no-key"), (1.017, "no-key"), (1.034, "request-key-single"), (1.051, "empty")] {
                try pair.observe(band: Self.band(name), at: time)
            }
            try pair.readAll(at: 1.06)
            pair.bind(hackID: 1)
            pair.summary(hackID: 1)
        }
        // interruptionMakesBothUncertainUntilALaterNoticeResolvesOne
        do {
            let pair = CapturePair()
            pair.interrupt(at: 0.5)
            try pair.observe(band: Self.band("complex"), at: 1)
            try pair.readAll(at: 1)
            pair.interrupt(at: 1.5)
            try pair.observe(band: Self.band("request-key-single"), at: 2)
            try pair.readAll(at: 2)
            pair.bind(hackID: 1)
            pair.summary(hackID: 1)
        }
        // secondSampleWaitsForASettledFrameAndExpiredCropsAreReported
        do {
            let pair = CapturePair()
            for time in [1.0, 1.017, 1.034, 1.051] { try pair.observe(band: Self.band("no-key"), at: time) }
            _ = try pair.take(at: 3)
            pair.takeDropped(); pair.takeDropped()
        }
        // invalidAndBlankAreNotAcceptedCommands
        do {
            let pair = CapturePair()
            try pair.observe(band: Self.band("invalid"), at: 1)
            try pair.readAll(at: 1)
            try pair.observe(band: Self.band("empty"), at: 1.05)
        }
        // overlayAfterValidNoticeMakesFinalUnknown
        do {
            let pair = CapturePair()
            try pair.observe(band: Self.band("no-key"), at: 1)
            try pair.readAll(at: 1)
            try pair.observe(band: Self.overlay(), at: 1.1)
            pair.bind(hackID: 1)
            pair.summary(hackID: 1)
        }
        // queueExpiryAndClockRestart
        do {
            let pair = CapturePair()
            try pair.observe(band: Self.band("no-key"), at: 10)
            _ = try pair.take(at: 12)
            pair.bind(hackID: 1)
            pair.summary(hackID: 1)
            try pair.observe(band: Self.band("request-key-single"), at: 1)
            try pair.readAll(at: 1)
            pair.bind(hackID: 2)
            pair.summary(hackID: 2)
        }
    }

    @Test("Every oracle scenario of the drone footer probe's capture gives the same reads, reuses and summaries")
    func droneScenarios() throws {
        let drone = try Self.fixture("Phases/field-00666.png")
        // realDroneFrame
        do {
            let pair = CapturePair()
            try pair.observeMode(in: drone, at: 1)
            _ = try pair.take(at: 1)
        }
        // gearPanelSkipsTheProbe
        do {
            let frame = try DroneFooterProbeTests.compose(try Self.fixture("Gear/multiplied-bonus.png"), bottom: drone)
            let pair = CapturePair()
            try pair.observeMode(in: frame, at: 1, panelShowing: true)
            try pair.observeMode(in: frame, at: 2.5, panelShowing: true)
            try pair.observeMode(in: frame, at: 3, panelShowing: false)
        }
        // otherScreens
        for path in ["Phases/field-00381.png", "Phases/field-00443.png", "Phases/field-00492.png",
                     "Phases/field-00615.png", "Recording/sample-23600.png", "Recording/sample-26300.png",
                     "Results/three-final.png", "PortalLevel/portal-l8.png", "PortalLevel/map-drop-602.png",
                     "OneGlyph/one-01868.png", "AssistiveTouch/touch-01903.png", "Gear/four-bonus.png",
                     "Languages/zh-bonus.png"] {
            let pair = CapturePair()
            try pair.observeMode(in: try Self.fixture(path), at: 1)
        }
        // confirmedFooterIsReused
        do {
            let pair = CapturePair()
            try pair.observeMode(in: drone, at: 1)
            let first = try #require(try pair.take(at: 1))
            try pair.observeMode(in: drone, at: 1.5)
            pair.accept(.init(notice: .drone, confidence: 1, language: "en"), first)
            pair.bind(hackID: 1)
            try pair.observeMode(in: drone, at: 10)
            try pair.observe(band: try Self.fixture("Commands/empty.png"), at: 11)
            pair.bind(hackID: 2)
            pair.summary(hackID: 2)
            try pair.observeMode(in: try Self.letters(), at: 20)
            let unknown = CapturePair()
            try unknown.observeMode(in: drone, at: 1)
            let read = try #require(try unknown.take(at: 1))
            unknown.accept(.init(notice: nil, confidence: 0), read)
            try unknown.observeMode(in: drone, at: 2)
        }
        // signatures
        let rect = DroneFooterProbe.textRect(width: drone.width, height: drone.height)
        let real = try #require(DroneFooterProbe.candidate(try ImageDecoder.decodeColor(drone, in: rect)))
        var shifted = real.signature
        #expect(CxxDroneFooterProbe.matches(shifted, real.signature) == DroneFooterProbe.matches(shifted, real.signature))
        for index in 0...DroneFooterProbe.signatureTolerance {
            shifted[index] ^= 1
            #expect(CxxDroneFooterProbe.matches(shifted, real.signature)
                == DroneFooterProbe.matches(shifted, real.signature))
        }
        #expect(CxxDroneFooterProbe.matches([], real.signature) == DroneFooterProbe.matches([], real.signature))
    }

    /// `CommandNoticeReader.read(_:languages:)`'s language logic over either
    /// memory, with `read` standing for the Vision read in a language.
    static func readNotice(at time: Double, memory: some GameLanguageRemembering,
                           read: (GameLanguage) throws -> CommandNoticeReading) rethrows -> CommandNoticeReading {
        let current = memory.current
        let reading = try read(current)
        guard reading.notice == nil else {
            if current != .english, reading.language == current.rawValue { memory.found(current) }
            return reading
        }
        for language in memory.alternatives(at: time, on: .notice) {
            let other = try read(language)
            if other.notice != nil, other.language == language.rawValue {
                memory.found(language)
                return other
            }
        }
        return reading
    }

    @Test("The recorded notices' language logic gives the same readings and memories in both arms")
    func languageScenarios() throws {
        let zh = try Self.fixture("Languages/zh-complex.png"), noKey = try Self.band("no-key")
        for (band, start, automatic) in [(zh, GameLanguage.english, true), (zh, .simplifiedChinese, true),
                                         (noKey, .english, true), (zh, .simplifiedChinese, false)] {
            let pair = CapturePair()
            try pair.observe(band: band, at: 1)
            let frames = try #require(try pair.take(at: 1))
            var cache: [GameLanguage: CommandNoticeReading] = [:]
            let read = { (language: GameLanguage) throws -> CommandNoticeReading in
                if let known = cache[language] { return known }
                let reading = try CommandNoticeReader(language: language).read(frames.swift)
                cache[language] = reading
                return reading
            }
            let swiftMemory = GameLanguageMemory(language: start, isAutomatic: automatic)
            let cxxMemory = CxxGameLanguageMemory(language: start, isAutomatic: automatic)
            let expected = try Self.readNotice(at: 1, memory: swiftMemory, read: read)
            let actual = try Self.readNotice(at: 1, memory: cxxMemory, read: read)
            #expect(expected == actual)
            #expect(swiftMemory.state == cxxMemory.state)
        }
    }

    @Test("Whether a footer probe is due agrees in both arms through candidates, reuses, a full queue, bind, cancel and invalidation")
    func modeProbeDueScenarios() throws {
        let drone = try Self.fixture("Phases/field-00666.png")
        let quiet = try Self.fixture("Phases/field-00381.png")
        let pair = CapturePair()
        #expect(pair.modeProbeDue(at: 0) && !pair.modeProbeDue(at: 0, panelShowing: true))
        // No candidate leaves the gate open on the next frame.
        #expect(try !pair.observeMode(in: quiet, at: 0.5))
        #expect(pair.modeProbeDue(at: 0.55))
        // A candidate queued for a read closes it for a second.
        #expect(try pair.observeMode(in: drone, at: 1))
        #expect(!pair.modeProbeDue(at: 1.05) && !pair.modeProbeDue(at: 1.999) && pair.modeProbeDue(at: 2))
        #expect(try !pair.observeMode(in: drone, at: 1.5), "inside the gate")
        // A read confirming the footer: the next candidate is a reuse, which
        // closes the gate too.
        let first = try #require(try pair.take(at: 1.1))
        pair.accept(.init(notice: .drone, confidence: 1, language: "en"), first)
        #expect(try pair.observeMode(in: drone, at: 2))
        #expect(pair.swift.modeReuses == 1)
        #expect(!pair.modeProbeDue(at: 2.5) && pair.modeProbeDue(at: 3))
        // An open command window stops probes until a bind or a cancel.
        try pair.observe(band: Self.band("no-key"), at: 2.2)
        #expect(!pair.modeProbeDue(at: 3.05) && !pair.modeProbeDue(at: 10))
        pair.bind(hackID: 1)
        #expect(!pair.modeProbeDue(at: 2.5) && pair.modeProbeDue(at: 3), "a bind keeps the last probe's gate")
        try pair.observe(band: Self.band("empty"), at: 3)
        #expect(!pair.modeProbeDue(at: 5))
        pair.cancel()
        #expect(pair.modeProbeDue(at: 3.05), "a cancel reopens the gate at once")
        #expect(try pair.observeMode(in: drone, at: 3.05))
        #expect(!pair.modeProbeDue(at: 3.1))
        pair.invalidateQueue(at: 3.1)
        #expect(pair.modeProbeDue(at: 3.1), "an invalidated queue reopens the gate at once")

        // A full queue takes the candidate but queues no read, and leaves the
        // gate open.
        let full = CapturePair()
        for second in 1...16 { #expect(try full.observeMode(in: drone, at: Double(second))) }
        #expect(full.swift.queue.count == 16 && full.swift.modeReads == 16)
        #expect(full.modeProbeDue(at: 17))
        #expect(try full.observeMode(in: drone, at: 17))
        #expect(full.swift.modeReads == 16 && full.swift.modeCandidates == 17)
        #expect(full.modeProbeDue(at: 17.5), "no read was queued, so the gate still counts from 16")
        #expect(try full.take(at: 17.5) == nil, "every read expired")
        #expect(try full.observeMode(in: drone, at: 17.5))
        #expect(full.swift.modeReads == 17 && !full.modeProbeDue(at: 18) && full.modeProbeDue(at: 18.5))
    }

    @Test("A dark band seen through observeEmptyBand leaves both arms as observe(band:) does, through every capture call",
          arguments: [1, 2, 3, 4] as [UInt64])
    func emptyBandMatchesDarkBand(seed: UInt64) throws {
        let dark = try Self.darkBand()
        let darkPixels = try ImageDecoder.decode(dark)
        #expect(darkPixels.pixels.max() == 45, "the band must reach the detector's threshold and stay at it")
        let bands = try ["no-key", "complex", "empty", "simple", "keys-only"].map(Self.band) + [try Self.overlay()]
        let screens = try [Self.fixture("Phases/field-00666.png"), Self.fixture("Phases/field-00381.png")]
        var random = PaceRandom(seed: seed)
        let byBand = CapturePair(), byPlanes = CapturePair()
        var clock = 1.0, hackID = 0, emptyBands = 0
        var taken: [(byBand: (swift: CommandNoticeFrame, cxx: CommandNoticeFrame),
                     byPlanes: (swift: CommandNoticeFrame, cxx: CommandNoticeFrame))] = []
        func compare(_ context: String) {
            #expect(byBand.swift.queue.map(PaceFrameFacts.init) == byPlanes.swift.queue.map(PaceFrameFacts.init),
                    "\(context)")
            #expect(byBand.swift.showsNotice == byPlanes.swift.showsNotice
                    && byBand.swift.modeCandidates == byPlanes.swift.modeCandidates
                    && byBand.swift.modeReads == byPlanes.swift.modeReads
                    && byBand.swift.modeReuses == byPlanes.swift.modeReuses, "\(context)")
            #expect(sameDouble(byBand.swift.noticeReadAt, byPlanes.swift.noticeReadAt), "\(context): notice read at")
            for offset in [0, 0.5, 1, 5] {
                #expect(byBand.swift.modeProbeDue(at: clock + offset) == byPlanes.swift.modeProbeDue(at: clock + offset),
                        "\(context): probe due")
            }
            for id in max(0, hackID - 4)...hackID + 1 {
                #expect(byBand.summary(hackID: id) == byPlanes.summary(hackID: id), "\(context): summary \(id)")
            }
        }
        for step in 0..<300 {
            switch random.below(100) {
            case 0..<3: clock -= random.double(0...3)
            case 3..<8: break
            default: clock += random.pick([0.017, 0.033, 0.05, random.double(0...0.6)])
            }
            switch random.below(100) {
            case 0..<35:
                try byBand.observe(band: dark, at: clock)
                byPlanes.observeEmptyBand(at: clock)
                emptyBands += 1
            case 35..<60:
                let band = random.pick(bands)
                try byBand.observe(band: band, at: clock)
                try byPlanes.observe(band: band, at: clock)
            case 60..<70:
                let screen = random.pick(screens), panelShowing = random.chance(20)
                try byBand.observeMode(in: screen, at: clock, panelShowing: panelShowing)
                try byPlanes.observeMode(in: screen, at: clock, panelShowing: panelShowing)
            case 70..<82:
                let first = try byBand.take(at: clock), second = try byPlanes.take(at: clock)
                #expect((first == nil) == (second == nil), "step \(step): take")
                if let first, let second { taken.append((first, second)) }
            case 82..<90 where !taken.isEmpty:
                let notice: CommandNoticeReading.Notice? = random.chance(80)
                    ? random.pick([.simple, .complex, .noKey, .keysOnly, .drone]) : nil
                let read = CommandNoticeReading(notice: notice, confidence: random.pick([0.5, 0.99, 1]),
                                                language: notice == nil ? nil : "en")
                let frames = taken.removeLast()
                byBand.accept(read, frames.byBand)
                byPlanes.accept(read, frames.byPlanes)
            case 90..<93: byBand.interrupt(at: clock); byPlanes.interrupt(at: clock)
            case 93..<97:
                hackID += 1
                byBand.bind(hackID: hackID); byPlanes.bind(hackID: hackID)
            default: byBand.cancel(); byPlanes.cancel()
            }
            compare("step \(step)")
        }
        #expect(emptyBands > 80)
    }

    @Test("Seeded random walks of 300 capture calls give the same queues, frames and summaries after every step",
          arguments: [1, 2, 3] as [UInt64])
    func randomWalk(seed: UInt64) throws {
        var random = PaceRandom(seed: seed)
        let bands = try ["no-key", "complex", "empty", "request-key-single", "simple", "invalid", "keys-only"]
            .map(Self.band) + [try Self.overlay()]
        let screens = try [Self.fixture("Phases/field-00666.png"), Self.fixture("Phases/field-00381.png"),
                           Self.letters()]
        let pair = CapturePair()
        var clock = 1.0, hackID = 0, frameCount = 0
        var taken: [(swift: CommandNoticeFrame, cxx: CommandNoticeFrame)] = []
        // One language per notice, so a confirmed read's language never
        // depends on the order of Swift's dictionary (see logic_command.cpp).
        let languages: [CommandNoticeReading.Notice: String] = [.simple: "en", .complex: "zh-Hans", .requestKey: "en",
                                                                .noKey: "ja", .keysOnly: "ko", .invalid: "en",
                                                                .drone: "en"]
        for _ in 0..<300 {
            switch random.below(100) {
            case 0..<3: clock -= random.double(0...3)
            case 3..<6: break
            default: clock += random.pick([0.017, 0.033, 0.05, random.double(0...0.6)])
            }
            switch random.below(100) {
            case 0..<40: try pair.observe(band: random.pick(bands), at: clock)
            case 40..<52: try pair.observeMode(in: random.pick(screens), at: clock, panelShowing: random.chance(20))
            case 52..<70:
                if let frames = try pair.take(at: clock) { taken.append(frames); frameCount += 1 }
            case 70..<84 where !taken.isEmpty:
                let notice: CommandNoticeReading.Notice? = random.chance(80)
                    ? random.pick([.simple, .complex, .requestKey, .noKey, .keysOnly, .invalid, .drone]) : nil
                let read = CommandNoticeReading(notice: notice, confidence: random.pick([0, 0.5, 0.85, 0.99, 1]),
                                                language: notice.flatMap { languages[$0] })
                pair.accept(read, random.chance(70) ? taken.removeLast() : random.pick(taken))
            case 84..<88: pair.interrupt(at: clock)
            case 88..<90: pair.invalidateQueue(at: clock)
            case 90..<95:
                hackID += random.chance(80) ? 1 : 0
                pair.bind(hackID: hackID)
            case 95..<97: pair.cancel()
            default: pair.takeDropped()
            }
            for id in max(0, hackID - 9)...hackID + 1 { pair.summary(hackID: id) }
        }
        #expect(pair.steps >= 300)
        #expect(frameCount > 10, "\(frameCount) frames taken")
    }
}

// MARK: - Portal level

private func samePortal(_ a: PortalScreenEvidence?, _ b: PortalScreenEvidence?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?):
        return sameDouble(a.sourceTime, b.sourceTime) && a.resonators == b.resonators && a.unreadSlots == b.unreadSlots
            && sameDouble(a.badgeHue, b.badgeHue) && a.faction == b.faction
    default: return false
    }
}

private final class PortalObserverPair {
    var swift = PortalLevelObserver()
    let cxx = CxxPortalLevelObserver()
    private(set) var steps = 0

    func accept(_ evidence: PortalScreenEvidence) {
        swift.accept(evidence); cxx.accept(evidence)
        steps += 1
    }

    @discardableResult
    func claim(at time: Double) -> PortalScreenEvidence? {
        let expected = swift.claim(at: time), actual = cxx.claim(at: time)
        steps += 1
        #expect(samePortal(expected, actual), "claim at \(time)")
        return expected
    }
}

@Suite("C++ pace: portal level")
struct CxxPacePortalTests {
    static func line(_ text: String, confidence: Double = 1) -> ResultTextLine {
        ResultTextLine(text: text, confidence: confidence, x: 0.05, y: 0.4, width: 0.1, height: 0.02)
    }

    /// Compared with the glyph count both settled and still open, as the
    /// command summary gives it.
    static func compareEstimate(_ screen: PortalScreenEvidence?, glyphCount: Int?) {
        for settled in [true, false] {
            #expect(PortalLevelRules.estimate(screen: screen, glyphCount: glyphCount, glyphCountSettled: settled)
                == CxxPortalLevelRules.estimate(screen: screen, glyphCount: glyphCount, glyphCountSettled: settled),
                "\(String(describing: screen)) settled \(settled)")
        }
    }

    static func compareEstimate(resonators: [Int]?, unreadSlots: Int?, badgeHue: Double?, glyphCount: Int?) {
        for settled in [true, false] {
            #expect(PortalLevelRules.estimate(resonators: resonators, unreadSlots: unreadSlots, badgeHue: badgeHue,
                                              glyphCount: glyphCount, glyphCountSettled: settled)
                == CxxPortalLevelRules.estimate(resonators: resonators, unreadSlots: unreadSlots, badgeHue: badgeHue,
                                                glyphCount: glyphCount, glyphCountSettled: settled),
                "\(String(describing: resonators)) \(String(describing: unreadSlots)) \(String(describing: badgeHue)) settled \(settled)")
        }
    }

    @Test("Every oracle scenario of PortalLevelTests gives the same levels, estimates and claims")
    func oracleScenarios() {
        for count in -1...7 {
            #expect(PortalLevelRules.levels(forGlyphCount: count) == CxxPortalLevelRules.levels(forGlyphCount: count))
        }
        for (read, unread) in [([8, 6, 7, 6, 6, 6, 8, 7], 0), (Array(repeating: 8, count: 8), 0), ([5, 4, 6], 5), ([], 0)] {
            #expect(PortalLevelRules.levels(forResonators: read, unread: unread)
                == CxxPortalLevelRules.levels(forResonators: read, unread: unread))
        }
        for hue in [259, 330, 344, 295, 10, 180.0] {
            #expect(PortalLevelRules.levels(forBadgeHue: hue) == CxxPortalLevelRules.levels(forBadgeHue: hue))
        }
        Self.compareEstimate(resonators: [8, 6, 7, 6, 6, 6, 8, 7], unreadSlots: 0, badgeHue: 329, glyphCount: 4)
        Self.compareEstimate(resonators: Array(repeating: 8, count: 8), unreadSlots: 0, badgeHue: nil, glyphCount: nil)
        Self.compareEstimate(resonators: [5, 4, 6], unreadSlots: 5, badgeHue: 343, glyphCount: 3)
        Self.compareEstimate(resonators: nil, unreadSlots: nil, badgeHue: nil, glyphCount: 4)
        Self.compareEstimate(resonators: Array(repeating: 8, count: 8), unreadSlots: 0, badgeHue: nil, glyphCount: 3)
        Self.compareEstimate(resonators: nil, unreadSlots: nil, badgeHue: nil, glyphCount: nil)
        // labels
        let labels = ["L8", "B1gHack3r", "l6 A", "I7", "18", "L 5", "TidepoolL..", "A L4", "k3r 9"].map { Self.line($0) }
        #expect(PortalScreenParser().read(lines: labels, badgeHue: nil, at: 1)
            == CxxPortalScreenParser().read(lines: labels, badgeHue: nil, at: 1))
        let none = ["L9", "L0", "x8", "L88"].map { Self.line($0) }
        #expect(PortalScreenParser().read(lines: none, badgeHue: nil, at: 1)
            == CxxPortalScreenParser().read(lines: none, badgeHue: nil, at: 1))
        // observer
        do {
            let pair = PortalObserverPair()
            pair.accept(PortalScreenEvidence(sourceTime: 10, resonators: [8, 8, 8], unreadSlots: 5, badgeHue: nil))
            pair.accept(PortalScreenEvidence(sourceTime: 10.25, resonators: [8], unreadSlots: 7, badgeHue: 259))
            Self.compareEstimate(pair.claim(at: 13), glyphCount: 5)
            Self.compareEstimate(pair.claim(at: 30), glyphCount: 3)
            pair.accept(PortalScreenEvidence(sourceTime: 40, resonators: [6, 6], unreadSlots: 6, badgeHue: 329))
            Self.compareEstimate(pair.claim(at: 55), glyphCount: 4)
            pair.accept(PortalScreenEvidence(sourceTime: 60, resonators: [8, 8, 8, 8], unreadSlots: 4, badgeHue: 259))
            pair.accept(PortalScreenEvidence(sourceTime: 63, resonators: [5], unreadSlots: 7, badgeHue: 343))
            Self.compareEstimate(pair.claim(at: 65), glyphCount: 3)
        }
        // observerFactionChange
        for faction in [PortalFaction.enlightened, .machina] {
            for count in [0, 1] {
                let pair = PortalObserverPair()
                pair.accept(PortalScreenEvidence(sourceTime: 10, resonators: Array(repeating: 8, count: 8),
                                                 unreadSlots: 0, badgeHue: 259, faction: .resistance))
                pair.accept(PortalScreenEvidence(sourceTime: 11, resonators: Array(repeating: 1, count: count),
                                                 unreadSlots: 8 - count, badgeHue: nil, faction: faction))
                pair.claim(at: 12)
                pair.claim(at: 13)
            }
        }
        // observerUnreadLaterScreen
        do {
            let pair = PortalObserverPair()
            pair.accept(PortalScreenEvidence(sourceTime: 10, resonators: [8, 8, 8], unreadSlots: 5, badgeHue: 259,
                                             faction: .resistance))
            pair.accept(PortalScreenEvidence(sourceTime: 12, resonators: [], unreadSlots: 8, badgeHue: nil,
                                             faction: .resistance))
            pair.claim(at: 13)
        }
        // observerFadingAndOutOfOrder
        do {
            let pair = PortalObserverPair()
            pair.accept(PortalScreenEvidence(sourceTime: 10, resonators: [1, 1, 1], unreadSlots: 5, badgeHue: nil,
                                             faction: .machina))
            pair.accept(PortalScreenEvidence(sourceTime: 10.5, resonators: [], unreadSlots: 8, badgeHue: 10,
                                             faction: .machina))
            pair.accept(PortalScreenEvidence(sourceTime: 9, resonators: [8, 8, 8, 8], unreadSlots: 4, badgeHue: 259,
                                             faction: .resistance))
            pair.claim(at: 11)
        }
        // observerLateCallback
        do {
            let pair = PortalObserverPair()
            pair.claim(at: 10)
            pair.accept(PortalScreenEvidence(sourceTime: 9, resonators: [8, 8, 8, 8], unreadSlots: 4, badgeHue: 259,
                                             faction: .resistance))
            pair.claim(at: 12)
        }
        // factionCarried
        do {
            let swiftEvidence = PortalScreenParser().read(lines: [], badgeHue: nil, at: 10, faction: .machina)
            #expect(swiftEvidence == CxxPortalScreenParser().read(lines: [], badgeHue: nil, at: 10, faction: .machina))
            let pair = PortalObserverPair()
            pair.accept(swiftEvidence)
            pair.claim(at: 11)
        }
        // yellowRule
        let hueSets: [[Double]] = [Array(repeating: 65, count: 40),
                                   Array(repeating: 65, count: 30) + Array(repeating: 280, count: 10),
                                   Array(repeating: 65, count: 10), Array(repeating: 280, count: 40),
                                   Array(repeating: 10, count: 40),
                                   Array(repeating: 65, count: 20) + Array(repeating: 258, count: 20)]
        for hues in hueSets {
            #expect(PortalScreenParser.isLevelOneYellow(hues: hues) == CxxPortalScreenParser.isLevelOneYellow(hues: hues))
        }
        let yellowLines = ["L7", "17", "L8", "L7", "L8 L8"].map { Self.line($0) }
        #expect(PortalScreenParser().read(lines: yellowLines, badgeHue: nil, at: 1, yellowLabels: [0, 1, 4])
            == CxxPortalScreenParser().read(lines: yellowLines, badgeHue: nil, at: 1, yellowLabels: [0, 1, 4]))
        // yellowEstimate
        let machina = ["L1", "L1", "L1", "L1", "L1", "L1", "L7"].map { Self.line($0) }
        let screen = PortalScreenParser().read(lines: machina, badgeHue: nil, at: 1, faction: .machina, yellowLabels: [6])
        #expect(screen == CxxPortalScreenParser().read(lines: machina, badgeHue: nil, at: 1, faction: .machina,
                                                      yellowLabels: [6]))
        Self.compareEstimate(screen, glyphCount: 1)
        // factionInEstimate
        Self.compareEstimate(PortalScreenEvidence(sourceTime: 1, resonators: Array(repeating: 1, count: 8), unreadSlots: 0,
                                                  badgeHue: nil, faction: .machina), glyphCount: 1)
        Self.compareEstimate(nil, glyphCount: 4)
    }

    @Test("Badge hues across and beyond the circle, resonator sets and estimates give the same levels")
    func rulesSweep() {
        var hue = -720.0
        while hue <= 1080 {
            #expect(PortalLevelRules.levels(forBadgeHue: hue) == CxxPortalLevelRules.levels(forBadgeHue: hue), "\(hue)")
            hue += 0.25
        }
        for special in [Double.nan, .infinity, -.infinity, 266, 266.000001, 322, 321.99999, 350.5, 350.50001, 60, 59.999] {
            #expect(PortalLevelRules.levels(forBadgeHue: special) == CxxPortalLevelRules.levels(forBadgeHue: special))
        }
        var random = PaceRandom(seed: 41)
        for _ in 0..<10_000 {
            let resonators: [Int]? = random.chance(80) ? (0..<random.below(9)).map { _ in random.below(12) - 1 } : nil
            let unread: Int? = random.chance(85) ? random.below(13) - 2 : nil
            let badge: Double? = random.chance(60) ? random.double(-30...400) : nil
            let glyphs: Int? = random.chance(70) ? random.below(8) - 1 : nil
            Self.compareEstimate(resonators: resonators, unreadSlots: unread, badgeHue: badge, glyphCount: glyphs)
            if let resonators {
                #expect(PortalLevelRules.levels(forResonators: resonators, unread: unread ?? 0)
                    == CxxPortalLevelRules.levels(forResonators: resonators, unread: unread ?? 0))
            }
            let faction: PortalFaction? = random.chance(70) ? random.pick(PortalFaction.allCases) : nil
            Self.compareEstimate(PortalScreenEvidence(sourceTime: random.double(0...100), resonators: resonators ?? [],
                                                      unreadSlots: unread ?? 0, badgeHue: badge, faction: faction),
                                 glyphCount: glyphs)
        }
    }

    @Test("Seeded random walks of 2,000 portal reads and claims give the same claims after every step",
          arguments: [1, 2, 3] as [UInt64])
    func observerWalk(seed: UInt64) {
        var random = PaceRandom(seed: seed)
        let pair = PortalObserverPair()
        var clock = 0.0
        for _ in 0..<2_000 {
            let time = paceTime(&random, clock: &clock)
            if random.chance(70) {
                let count = random.below(9)
                pair.accept(PortalScreenEvidence(
                    sourceTime: time, resonators: (0..<count).map { _ in 1 + random.below(8) }, unreadSlots: 8 - count,
                    badgeHue: random.chance(50) ? random.double(0...360) : nil,
                    faction: random.chance(80) ? random.pick(PortalFaction.allCases) : nil))
            } else {
                pair.claim(at: time)
            }
        }
        #expect(pair.steps == 2_000)
    }

    @Test("Random label lines give the same levels and evidence")
    func labelWalk() {
        var random = PaceRandom(seed: 42)
        let tokens = ["L", "l", "I", "|", "1", "2", "5", "7", "8", "9", "0", "A", "^", " ", " ", "\t", "\u{3000}", "18", "L8",
                      "Ｌ", "８", "八", "①", "٣", "\u{301}", "x", "Agent", "\u{200D}", "\n", "L\u{301}", "5\u{20E3}"]
        for _ in 0..<5_000 {
            let text = (0..<(1 + random.below(6))).map { _ in random.pick(tokens) }.joined()
            #expect(PortalScreenParser.levels(in: text) == CxxPortalScreenParser.levels(in: text),
                    "\(CxxTextTests.hex(text))")
        }
        for _ in 0..<1_000 {
            let lines = (0..<random.below(12)).map { _ in
                Self.line((0..<(1 + random.below(4))).map { _ in random.pick(tokens) }.joined(),
                          confidence: random.pick([0.3, 0.39, 0.4, 0.9, 1, .nan]))
            }
            let yellow = Set((0..<random.below(4)).map { _ in random.below(12) })
            let badge: Double? = random.chance(50) ? random.double(0...360) : nil
            let faction: PortalFaction? = random.chance(50) ? random.pick(PortalFaction.allCases) : nil
            #expect(samePortal(PortalScreenParser().read(lines: lines, badgeHue: badge, at: 3, faction: faction,
                                                         yellowLabels: yellow),
                               CxxPortalScreenParser().read(lines: lines, badgeHue: badge, at: 3, faction: faction,
                                                            yellowLabels: yellow)))
            let hues = (0..<random.below(60)).map { _ in random.chance(50) ? random.double(40...90) : random.double(0...360) }
            #expect(PortalScreenParser.isLevelOneYellow(hues: hues) == CxxPortalScreenParser.isLevelOneYellow(hues: hues))
        }
    }
}
